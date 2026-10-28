import BMWCodingCore
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// The mechanic's settings, kept as JSON in the user defaults: the model, the effort of chat turns, and the prices the
/// cost estimates use.
struct AISettings: Codable, Equatable {
    var model = "claude-opus-5-5"
    var effort = "medium"
    var prices = PriceTable.standard

    /// The models to choose from: the name the API knows, then the one shown.
    static let models = [
        ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-haiku-5-5", "Haiku 5.5"),
    ]
    static let efforts = ["low", "medium", "high"]
    private static let defaultsKey = "aiSettings"

    /// The saved settings, or the defaults when none are saved or they cannot be read.
    static func load() -> AISettings {
        let saved = UserDefaults.standard.data(forKey: defaultsKey)
        return saved.flatMap { try? JSONDecoder().decode(AISettings.self, from: $0) } ?? AISettings()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// The state of the AI step: the health check, the conversation about the connected car, the turn in progress, and
/// the settings. It reaches the car through `flow`, holding `flow.busy` whenever it uses the adapter. The health check
/// and the turns share one `Diag` and never overlap: each holds `busy`, and `phase` says which one runs.
@Observable @MainActor
final class AIFlow {
    enum Phase: Equatable {
        /// No conversation is open.
        case idle
        /// The health check runs; what it is doing.
        case checking(String)
        /// A conversation is open and waits for the owner.
        case ready
        /// The mechanic is answering.
        case answering
    }

    private(set) var phase = Phase.idle
    private(set) var conversation: Conversation?
    /// The assistant text of the turn in progress.
    private(set) var streaming = ""
    /// The reads and web lookups of the turn in progress, a line each.
    private(set) var activity: [String] = []
    var error: String?
    var settings: AISettings
    private(set) var hasKey: Bool
    private unowned let flow: Flow
    /// The health check or the turn in progress, which Stop cancels.
    @ObservationIgnored private var turnTask: Task<Void, Never>?

    init(flow: Flow) {
        self.flow = flow
        settings = .load()
        hasKey = Keychain.apiKey() != nil
    }

    /// Opens the conversation saved for the connected car, or runs the health check when there is none. Does nothing
    /// without a key, without a connected car whose VIN was read, or while a check or a turn runs.
    func enter() async {
        guard hasKey, flow.diag != nil, let vin = flow.vin, phase == .idle || phase == .ready else { return }
        if conversation?.vin != vin { conversation = store.load(vin: vin) }
        if conversation == nil { await healthCheck() } else { phase = .ready }
    }

    /// Reads every module's fault codes and standard OBD-II, starts a conversation from what it found, and has the
    /// mechanic summarize it. Scans for modules first when none is listed. A check that fails leaves no
    /// conversation, so it can be run again.
    func healthCheck() async {
        error = nil
        if flow.modules.isEmpty {
            await flow.discover()
            guard !flow.modules.isEmpty else { error = flow.error ?? "No module answered the scan"; return }
        }
        let task = Task { await checkAndSummarize() }
        turnTask = task
        await task.value
    }

    /// Sends the owner's `text` and has the mechanic answer it.
    func send(_ text: String) {
        guard phase == .ready, conversation != nil else { return }
        conversation?.messages.append(Self.textMessage("user", text))
        turnTask = Task { await runTurn(effort: settings.effort) }
    }

    /// Stops the health check or the turn in progress.
    func stop() {
        turnTask?.cancel()
    }

    /// Deletes this car's conversation and starts a new one from a new health check.
    func newConversation() async {
        guard let vin = flow.vin else { return }
        do {
            try store.delete(vin: vin)
        } catch {
            self.error = "Could not delete the conversation: \(error.localizedDescription)"
            return
        }
        conversation = nil
        phase = .idle
        await healthCheck()
    }

    /// Deletes the saved conversations of every car.
    func clearConversations() {
        do {
            try store.deleteAll()
        } catch {
            self.error = "Could not clear the conversations: \(error.localizedDescription)"
            return
        }
        conversation = nil
        phase = .idle
    }

    /// Saves `key`, without the blanks around it, as the API key.
    func saveKey(_ key: String) {
        do {
            try Keychain.setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
            hasKey = true
        } catch {
            self.error = "Could not save the key: \(error)"  // a KeychainError, which holds only its status
        }
    }

    func removeKey() {
        do {
            try Keychain.deleteAPIKey()
            hasKey = false
        } catch {
            self.error = "Could not remove the key: \(error)"
        }
    }

    func saveSettings() {
        settings.save()
    }

    /// The estimated cost of the conversation so far, each turn at its own model's price; nil when one of those
    /// models has no price.
    var totalCost: Double? {
        var total = 0.0
        for turn in conversation?.turns ?? [] {
            guard let cost = settings.prices.cost(of: turn.usage, model: turn.model) else { return nil }
            total += cost
        }
        return total
    }

    /// The activity line for a web search or fetch the API ran (a `server_tool_use` block); nil for another tool.
    static func serverToolLine(_ block: JSON) -> String? {
        switch block["name"]?.string {
        case "web_search": "Searched the web: \"\(block["input"]?["query"]?.string ?? "")\""
        case "web_fetch": "Fetched \(block["input"]?["url"]?.string ?? "")"
        default: nil
        }
    }

    /// The health check proper, then the summary as the conversation's first turn.
    private func checkAndSummarize() async {
        guard case let (diag, car)? = connectedCar() else { error = "Not connected"; return }
        var opened = false
        await working("Reading the car's fault codes") {
            phase = .checking("Reading fault codes …")
            do {
                let mechanic = Mechanic(diag: diag, car: car, log: flow.log)
                let check = try await mechanic.healthCheck { phase = .checking($0) }
                let conversation = Conversation(
                    vin: car.vin, started: .now, model: settings.model, carContext: check.contextJSON,
                    messages: [Self.textMessage("user", Mechanic.firstQuestion)])
                try store.save(conversation)
                self.conversation = conversation
                opened = true
            } catch {
                self.conversation = nil
                phase = .idle
                self.error = error is CancellationError ? "Stopped" : Flow.describe(error)
            }
        }
        if opened { await runTurn(effort: "high") }
    }

    /// Has the mechanic answer the owner message the conversation ends with, streaming its text into `streaming` and
    /// its reads into `activity`, then records the turn. A stop keeps the text streamed so far; an error keeps the
    /// conversation as it was before the answer. Either way the conversation is saved and never holds a tool call
    /// without its result.
    private func runTurn(effort: String) async {
        guard var conversation else { return }
        guard case let (diag, car)? = connectedCar() else { error = "Not connected"; phase = .ready; return }
        guard let key = Keychain.apiKey() else { error = "No API key: enter one in Settings"; phase = .ready; return }
        await working("Answering with the AI mechanic") {
            error = nil
            phase = .answering
            streaming = ""
            activity = []
            let mechanic = Mechanic(diag: diag, car: car, log: flow.log)
            mechanic.beginMessage()
            let client = ClaudeClient(transport: URLSessionTransport(), apiKey: key, log: flow.log)
            let model = settings.model
            let ownerMessage = conversation.messages.count - 1
            // `run` holds its `inout` across awaits, so it works on a copy that goes back only once it returns.
            var messages = conversation.messages
            do {
                let turn = try await client.run(
                    messages: &messages, system: Mechanic.systemPrompt(carContext: conversation.carContext),
                    tools: Mechanic.tools, model: model, effort: effort,
                    runTool: { call in
                        let result = try await mechanic.run(call)
                        activity.append(Mechanic.activityLine(for: call, result: result, car: car))
                        return result
                    },
                    onUpdate: { update in
                        switch update {
                        case .text(let text): streaming += text
                        case .block(let block) where block["type"]?.string == "server_tool_use":
                            if let line = Self.serverToolLine(block) { activity.append(line) }
                        default: break  // `.finished` ends each request of the turn, not the turn
                        }
                    })
                conversation.messages = messages
                conversation.turns.append(TurnRecord(
                    messageIndex: ownerMessage, usage: turn.usage, rounds: turn.rounds, refused: turn.refused,
                    truncated: turn.truncated, stoppedAtRoundCap: turn.stoppedAtRoundCap, stopped: false, model: model))
            } catch is CancellationError {
                if !streaming.isEmpty { conversation.messages.append(Self.textMessage("assistant", streaming)) }
                conversation.turns.append(TurnRecord(
                    messageIndex: ownerMessage, usage: .zero, rounds: 0, refused: false, truncated: false,
                    stoppedAtRoundCap: false, stopped: true, model: model))
            } catch ClaudeError.api(_, let type, let message) {
                error = "API error (\(type)): \(message)"
            } catch ClaudeError.badToolInput {
                error = "The model sent an unreadable tool request; ask again"
            } catch ClaudeError.network(let message) {
                error = "No connection to Anthropic: \(message)"
            } catch {
                self.error = Flow.describe(error)
            }
            self.conversation = conversation
            do {
                try store.save(conversation)
            } catch {
                self.error = "Could not save the conversation: \(error.localizedDescription)"
            }
            phase = .ready
        }
    }

    /// Runs `body` holding `flow.busy`, the adapter's one-thing-at-a-time guard, with the Mac kept awake and the
    /// iPhone's screen on as for a backup, since sleep would drop the adapter. Says `Still working` instead when
    /// something else holds `busy`.
    private func working(_ reason: String, _ body: () async -> Void) async {
        guard !flow.busy else { error = "Still working"; return }
        flow.busy = true
        defer { flow.busy = false }
        let awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason)
        defer { ProcessInfo.processInfo.endActivity(awake) }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        await body()
    }

    /// The `Diag` to the connected car and the car as the mechanic sees it; nil when no car is connected with its VIN
    /// read.
    private func connectedCar() -> (diag: Diag, car: MechanicCar)? {
        guard let diag = flow.diag, let vin = flow.vin, let adapter = flow.adapter else { return nil }
        let car = MechanicCar(
            vin: vin, nickname: flow.car?.nickname ?? "", adapter: adapter, modules: flow.modules,
            latestBackup: flow.latestBackup())
        return (diag, car)
    }

    private var store: ConversationStore { ConversationStore(directory: flow.appFolder()) }

    /// A message of `role` holding one text block.
    private static func textMessage(_ role: String, _ text: String) -> JSON {
        .object(["role": .string(role), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }
}
