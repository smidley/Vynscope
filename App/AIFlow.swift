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

    /// Opens the conversation saved for the connected car or, when there is none and a key is saved, runs the health
    /// check. Does nothing without a connected car whose VIN was read, or while a check or a turn runs.
    func enter() async {
        guard flow.diag != nil, let vin = flow.vin, phase == .idle || phase == .ready else { return }
        if conversation?.vin != vin { conversation = store.load(vin: vin) }
        phase = conversation == nil ? .idle : .ready
        if conversation == nil, hasKey { await healthCheck() }
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
        phase = .answering  // before anything awaits, so that a second send or a health check cannot slip in
        conversation?.messages.append(Self.textMessage("user", text))
        turnTask = Task { await runTurn(effort: settings.effort) }
    }

    /// Whether the conversation ends with an owner message that got no answer, because its turn failed or was
    /// stopped before any text, so that `retry()` can run it again.
    var canRetry: Bool {
        guard phase == .ready, let last = conversation?.messages.last else { return false }
        return Self.isOwnerMessage(last)
    }

    /// Runs the unanswered owner message the conversation ends with again, adding no message; the health check's
    /// first question at high effort, as the check runs it.
    func retry() {
        guard canRetry, let conversation else { return }
        phase = .answering  // as in `send`
        let effort = conversation.messages.count == 1 ? "high" : settings.effort
        turnTask = Task { await runTurn(effort: effort) }
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
        error = nil
        conversation = nil
        phase = .idle
    }

    /// Saves `key`, without the blanks around it, as the API key, and clears the error, such as the `No API key`
    /// a turn left.
    func saveKey(_ key: String) {
        do {
            try Keychain.setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
            hasKey = true
            error = nil
        } catch {
            self.error = "Could not save the key: \(error)"  // a KeychainError: the system's text for its status
        }
    }

    func removeKey() {
        do {
            try Keychain.deleteAPIKey()
            hasKey = false
            error = nil
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

    /// Whether `message` is one the owner wrote: a user message with text, not one that carries tool results.
    static func isOwnerMessage(_ message: JSON) -> Bool {
        message["role"]?.string == "user"
            && (message["content"]?.array ?? []).contains { $0["type"]?.string == "text" }
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
    /// its reads into `activity`, then records the turn with what its requests used and its activity. A stop keeps
    /// the text streamed so far; an error keeps the conversation as it was before the answer and records the error.
    /// Either way the conversation is saved, never holds a tool call without its result, and is ready for the next
    /// message, also when the turn could not start.
    private func runTurn(effort: String) async {
        guard var conversation else { return }
        defer { phase = .ready }
        guard case let (diag, car)? = connectedCar() else { error = "Not connected"; return }
        guard let key = Keychain.apiKey() else { error = "No API key: enter one in Settings"; return }
        await working("Answering with the AI mechanic") {
            error = nil
            phase = .answering
            let mechanic = Mechanic(diag: diag, car: car, log: flow.log)
            mechanic.beginMessage()
            let client = ClaudeClient(transport: URLSessionTransport(), apiKey: key, log: flow.log)
            let model = settings.model
            let ownerMessage = conversation.messages.count - 1
            // What the turn's completed requests used, which a stopped or failed turn records too.
            var usage = Usage.zero
            // A tool call, a result or the end of a request came after the last text: the next text starts after a
            // blank line, where the saved answer starts another bubble.
            var textBroken = false
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
                        case .text(let text):
                            if textBroken, !streaming.isEmpty { streaming += "\n\n" }
                            textBroken = false
                            streaming += text
                        case .block(let block):
                            if block["type"]?.string == "server_tool_use", let line = Self.serverToolLine(block) {
                                activity.append(line)
                            }
                            if block["type"]?.string != "text" { textBroken = true }
                        case .finished:
                            textBroken = true  // the end of one request of the turn, not of the turn
                        }
                    },
                    onUsage: { usage = usage + $0 })
                conversation.messages = messages
                conversation.turns.append(TurnRecord(
                    messageIndex: ownerMessage, usage: turn.usage, rounds: turn.rounds, refused: turn.refused,
                    truncated: turn.truncated, stoppedAtRoundCap: turn.stoppedAtRoundCap, stopped: false, model: model,
                    activity: activity))
            } catch is CancellationError {
                let text = streaming.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { conversation.messages.append(Self.textMessage("assistant", text)) }
                conversation.turns.append(TurnRecord(
                    messageIndex: ownerMessage, usage: usage, rounds: 0, refused: false, truncated: false,
                    stoppedAtRoundCap: false, stopped: true, model: model, activity: activity))
            } catch {
                let text = switch error {
                case ClaudeError.api(_, let type, let message): "API error (\(type)): \(message)"
                case ClaudeError.badToolInput: "The model sent an unreadable tool request; ask again"
                case ClaudeError.network(let message): "No connection to Anthropic: \(message)"
                default: Flow.describe(error)
                }
                self.error = text
                conversation.turns.append(TurnRecord(
                    messageIndex: ownerMessage, usage: usage, rounds: 0, refused: false, truncated: false,
                    stoppedAtRoundCap: false, stopped: false, model: model, error: text, activity: activity))
            }
            self.conversation = conversation
            // The turn is in the conversation now; the next one starts from nothing, even before it runs.
            streaming = ""
            activity = []
            do {
                try store.save(conversation)
            } catch {
                self.error = "Could not save the conversation: \(error.localizedDescription)"
            }
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
