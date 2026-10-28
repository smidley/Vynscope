import BMWCodingCore
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// The mechanic's settings, kept as JSON in the user defaults: the provider, the model of each, the effort of chat
/// turns, and the prices the cost estimates use.
struct AISettings: Codable, Equatable {
    var provider = Provider.anthropic
    /// The Anthropic model.
    var model = "claude-opus-5-5"
    /// The OpenAI model, picked from the list the signed-in account offers; `nil` until that list was fetched.
    var openAIModel: String?
    var effort = "medium"
    var prices = PriceTable.standard

    init() {}

    /// Reads settings as `save` wrote them. A field the record lacks keeps its default, so that a record from before
    /// there were providers, with no `provider` and no `openAIModel`, still loads, where `load()` would otherwise give
    /// up on it and reset the owner's settings.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? provider
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel)
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? effort
        prices = try container.decodeIfPresent(PriceTable.self, forKey: .prices) ?? prices
    }

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

/// The state of the AI step: the health check, the conversation about the connected car, the turn in progress, the
/// settings, and the sign-in to ChatGPT. It reaches the car through `flow`, holding `flow.busy` whenever it uses the
/// adapter. The health check and the turns share one `Diag` and never overlap: each holds `busy`, and `phase` says
/// which one runs.
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
    /// The ChatGPT sign-in, as kept in the Keychain.
    private(set) var chatGPT: ChatGPTAccount?
    /// A sign-in waits for the browser or completes.
    private(set) var signingIn = false
    /// The sign-in page, which the iPhone shows in a Safari sheet while this is set.
    var signInURL: URL?
    /// The models the ChatGPT account lists: the id the API takes, then the name shown.
    private(set) var openAIModels: [(id: String, name: String)] = []
    /// The welcome to plan usage, shown once after the first sign-in that allows it.
    var showWelcome = false
    private unowned let flow: Flow
    private let session: ChatGPTSession
    /// The health check or the turn in progress, which Stop cancels.
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    /// The wait for the sign-in's redirect, which Cancel and the Safari sheet's dismissal end.
    @ObservationIgnored private var signInTask: Task<URL, any Error>?
    private static let welcomeShownKey = "chatgptWelcomeShown"

    init(flow: Flow) {
        self.flow = flow
        settings = .load()
        hasKey = Keychain.apiKey() != nil
        session = ChatGPTSession(store: KeychainAccountStore(), transport: URLSessionHTTPTransport(), log: flow.log)
        chatGPT = session.account
    }

    /// Whether the picked provider can answer: an API key is saved, or a ChatGPT sign-in may use the plan.
    var hasCredentials: Bool {
        switch settings.provider {
        case .anthropic: hasKey
        case .openai: chatGPT?.mayUsePlan == true
        }
    }

    /// Opens the conversation saved for the connected car or, when there is none and the provider's credentials are
    /// in, runs the health check. Does nothing without a connected car whose VIN was read, or while a check or a turn
    /// runs.
    func enter() async {
        guard flow.diag != nil, let vin = flow.vin, phase == .idle || phase == .ready else { return }
        if conversation?.vin != vin { conversation = store.load(vin: vin) }
        phase = conversation == nil ? .idle : .ready
        if conversation == nil, hasCredentials { await healthCheck() }
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

    /// Saves the provider just picked.
    func switchProvider() async {
        saveSettings()
    }

    /// Signs in with ChatGPT: starts the listener for the redirect, then opens OpenAI's sign-in page, in the default
    /// browser on the Mac or in the Safari sheet on the iPhone, and waits for the redirect, which `cancelSignIn()`
    /// ends. Then completes the sign-in, loads the model list and, the first time, shows the welcome. The sign-in
    /// page's URL is never logged.
    func signInToChatGPT() async {
        guard !signingIn else { return }
        signingIn = true
        error = nil
        let listener = LoopbackListener()
        defer {
            listener.stop()
            signInTask = nil
            signInURL = nil
            signingIn = false
        }
        let redirect: URL
        do {
            redirect = try await listener.start()
        } catch {
            self.error = "Could not start the sign-in: \(error.localizedDescription)"
            return
        }
        let (url, attempt) = session.begin(redirect: redirect)
        let wait = Task { try await listener.callback() }
        signInTask = wait
        #if os(macOS)
        ChatGPTBrowser.open(url)
        #else
        signInURL = url
        #endif
        do {
            let callback = try await wait.value
            // The redirect is in: the Safari sheet goes, and its dismissal or Cancel no longer ends anything.
            signInTask = nil
            signInURL = nil
            #if os(macOS)
            ChatGPTBrowser.returnToApp()
            #endif
            chatGPT = try await session.complete(callback: callback, attempt: attempt, redirect: redirect)
            error = nil
            await loadOpenAIModels()
            if !UserDefaults.standard.bool(forKey: Self.welcomeShownKey) {
                showWelcome = true
                UserDefaults.standard.set(true, forKey: Self.welcomeShownKey)
            }
        } catch is CancellationError {
            // Cancel, or the sheet dismissed: nothing to say.
        } catch let failure as SignInError {
            switch failure {
            case .denied: error = "Sign-in was cancelled in the browser"
            case .planNotGranted: chatGPT = session.account  // kept, without plan usage, as the row then says
            case .differentAccount: error = "That is a different ChatGPT account. Sign out first."
            case .stateMismatch, .clientMismatch, .registrationIncomplete, .missingCode, .signedOut:
                error = "The sign-in did not complete; try again"
            case .tokenEndpoint(_, let code, let description):
                error = "Sign-in failed (\(code)): \(description ?? code)"
            case .invalidIDToken(let check): error = "The sign-in could not be verified (\(check))"
            case .network(let text): error = "No connection to OpenAI: \(text)"
            }
        } catch {
            self.error = "The sign-in did not complete: \(error.localizedDescription)"
        }
    }

    /// Ends the wait for the sign-in's redirect, and with it the listener; nothing once the redirect is in.
    func cancelSignIn() {
        signInTask?.cancel()
    }

    /// Revokes the ChatGPT sign-in at OpenAI and forgets it here, confirmed or not.
    func signOutOfChatGPT() async {
        let result = await session.signOut()
        chatGPT = nil
        openAIModels = []
        error = result == .unconfirmed
            ? "Signed out here, but OpenAI did not confirm it. You can disconnect Vynscope in ChatGPT Settings." : nil
    }

    /// Fetches the models the ChatGPT account lists, in the server's order: those whose `visibility` is `list`, or
    /// every one when none has a `visibility`. The picked model becomes the first listed when it is not among them. A
    /// failure keeps the list as it was.
    func loadOpenAIModels() async {
        let reply: HTTPReply
        do {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            let token = try await session.validAccessToken(forPlanUse: false)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            reply = try await URLSessionHTTPTransport().send(request)
        } catch SignInError.signedOut {
            // The session dropped the sign-in, or replaced it with one that completed meanwhile.
            chatGPT = session.account
            if chatGPT == nil { error = "Sign in to ChatGPT again in Settings" }
            return
        } catch {
            guard !Task.isCancelled else { return }  // the sheet closed
            let text = if case SignInError.network(let text) = error { text } else { error.localizedDescription }
            self.error = "Could not load the model list: \(text)"
            return
        }
        let body = try? JSON.parse(reply.body)
        guard (200..<300).contains(reply.status), let entries = body?["data"]?.array else {
            error = "Could not load the model list: \(body?["error"]?["message"]?.string ?? "HTTP \(reply.status)")"
            return
        }
        let listed = entries.contains { $0["visibility"] != nil }
            ? entries.filter { $0["visibility"]?.string == "list" } : entries
        openAIModels = listed.compactMap { entry in
            guard let id = entry["slug"]?.string ?? entry["id"]?.string else { return nil }
            return (id, entry["display_name"]?.string ?? entry["id"]?.string ?? id)
        }
        if !openAIModels.contains(where: { $0.id == settings.openAIModel }) {
            settings.openAIModel = openAIModels.first?.id
            saveSettings()  // the sheet may have closed while the sign-in ran
        }
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
