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
    /// The last turn ended at the ChatGPT plan's usage limit, which the chat says in place of its error; the next
    /// question or Try again clears it.
    private(set) var planLimited = false
    /// The OpenAI models that refused web search on this account, which every later turn asks without it.
    private(set) var webSearchUnavailable: Set<String> = []
    private unowned let flow: Flow
    private let session: ChatGPTSession
    /// The health check or the turn in progress, which Stop cancels.
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    /// The wait for the sign-in's redirect, which Cancel and the Safari sheet's dismissal end.
    @ObservationIgnored private var signInTask: Task<URL, any Error>?
    private static let welcomeShownKey = "chatgptWelcomeShown"
    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!

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

    /// Opens the picked provider's conversation saved for the connected car or, when there is none and the provider's
    /// credentials are in, runs the health check. Does nothing without a connected car whose VIN was read, or while a
    /// check or a turn runs.
    func enter() async {
        guard flow.diag != nil, let vin = flow.vin, phase == .idle || phase == .ready else { return }
        if conversation?.vin != vin || conversation?.provider != settings.provider {
            conversation = store.load(vin: vin, provider: settings.provider)
            planLimited = false  // that was another conversation's last turn
        }
        phase = conversation == nil ? .idle : .ready
        if conversation == nil, hasCredentials { await healthCheck() }
    }

    /// Reads every module's fault codes and standard OBD-II, starts a conversation with the picked provider from what
    /// it found, and has the mechanic summarize it. Scans for modules first when none is listed. A check that fails
    /// leaves no conversation, so it can be run again. Reads nothing while no OpenAI model is picked.
    func healthCheck() async {
        error = nil
        planLimited = false
        guard model(for: settings.provider) != nil else { error = "Pick a model in Settings"; return }
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
        guard phase == .ready, let provider = conversation?.provider else { return }
        phase = .answering  // before anything awaits, so that a second send or a health check cannot slip in
        planLimited = false
        conversation?.messages.append(Mechanic.ownerMessage(text, provider: provider))
        turnTask = Task { await runTurn(effort: settings.effort) }
    }

    /// Whether `retry()` can run the owner message the conversation ends with again: it got no answer, because its
    /// turn failed or was stopped before any text, or the plan's usage limit cut its answer off.
    var canRetry: Bool {
        guard phase == .ready, let conversation, let last = conversation.messages.last else { return false }
        return planLimited || Mechanic.isOwnerMessage(last, provider: conversation.provider)
    }

    /// Runs the owner message the conversation ends with again, adding no message; the health check's first question
    /// at high effort, as the check runs it. The part of an answer the plan's usage limit kept gives way to the answer.
    func retry() {
        guard canRetry, var conversation, let last = conversation.messages.last else { return }
        if !Mechanic.isOwnerMessage(last, provider: conversation.provider) {
            conversation.messages.removeLast()
            self.conversation = conversation
        }
        phase = .answering  // as in `send`
        planLimited = false
        let effort = conversation.messages.count == 1 ? "high" : settings.effort
        turnTask = Task { await runTurn(effort: effort) }
    }

    /// Stops the health check or the turn in progress.
    func stop() {
        turnTask?.cancel()
    }

    /// Deletes this car's conversation with the picked provider and starts a new one from a new health check.
    func newConversation() async {
        guard let vin = flow.vin else { return }
        do {
            try store.delete(vin: vin, provider: settings.provider)
        } catch {
            self.error = "Could not delete the conversation: \(error.localizedDescription)"
            return
        }
        conversation = nil
        phase = .idle
        await healthCheck()
    }

    /// Deletes the picked provider's saved conversations of every car; the other provider's stay.
    func clearConversations() {
        do {
            try store.deleteAll(provider: settings.provider)
        } catch {
            self.error = "Could not clear the conversations: \(error.localizedDescription)"
            return
        }
        error = nil
        conversation = nil
        phase = .idle
        planLimited = false
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

    /// Shows the conversation of the provider just picked for the connected car or, when there is none and the
    /// provider's credentials are in, runs the health check. Nothing while a check or a turn runs.
    func switchProvider() async {
        guard !flow.busy else { return }
        conversation = flow.vin.flatMap { store.load(vin: $0, provider: settings.provider) }
        phase = conversation == nil ? .idle : .ready
        planLimited = false
        error = nil
        if conversation == nil, hasCredentials, flow.diag != nil { await healthCheck() }
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
            case .callbackError(let code, let description):
                error = "The sign-in failed (\(code)\(description.map { ": \($0)" } ?? "")). Try again."
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

    /// Ends the wait for the sign-in's redirect, and with it the listener; nothing once the redirect is in. With no
    /// account held, a sign-in that got no redirect may have stopped at a registration OpenAI no longer knows: the
    /// registration is dropped, and the next sign-in registers the app again.
    func cancelSignIn() {
        guard let signInTask else { return }
        signInTask.cancel()
        if chatGPT == nil { session.dropRegistration() }
    }

    /// Revokes the ChatGPT sign-in at OpenAI and forgets it here, confirmed or not. When the session held no account
    /// (the row was stale), the registration is dropped too, and the next sign-in registers the app again.
    func signOutOfChatGPT() async {
        let held = session.account != nil
        let result = await session.signOut()
        if !held { session.dropRegistration() }
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
            let failure = body?["error"], message = failure?["message"]?.string
            error = reply.status == 403 && failure?["code"]?.string == "subscription_sharing_user_not_eligible"
                ? Self.notEligible(message ?? "")
                : "Could not load the model list: \(message ?? "HTTP \(reply.status)")"
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

    /// The estimated cost of the conversation's Anthropic turns so far, each at its own model's price; nil when one of
    /// those models has no price. Turns on the ChatGPT plan cost nothing here.
    var totalCost: Double? {
        var total = 0.0
        for turn in conversation?.turns ?? [] where turn.provider == .anthropic {
            guard let cost = settings.prices.cost(of: turn.usage, model: turn.model) else { return nil }
            total += cost
        }
        return total
    }

    /// The activity line for a web search or a page fetch the API ran itself: an Anthropic `server_tool_use` block or
    /// an OpenAI `web_search_call` item; nil for anything else.
    static func serverToolLine(_ block: JSON) -> String? {
        switch block["type"]?.string {
        case "server_tool_use":
            switch block["name"]?.string {
            case "web_search": searchLine(block["input"]?["query"]?.string ?? "")
            case "web_fetch": fetchLine(block["input"]?["url"]?.string ?? "")
            default: nil
            }
        case "web_search_call":
            switch block["action"]?["type"]?.string {
            case "search": searchLine(block["action"]?["query"]?.string ?? "")
            case "open_page": fetchLine(block["action"]?["url"]?.string ?? "")
            default: nil
            }
        default: nil
        }
    }

    /// `Searched the web: "<query>"`.
    static func searchLine(_ query: String) -> String { "Searched the web: \"\(query)\"" }

    /// `Fetched <url>`.
    static func fetchLine(_ url: String) -> String { "Fetched \(url)" }

    /// The health check proper, then the summary as the conversation's first turn.
    private func checkAndSummarize() async {
        guard case let (diag, car)? = connectedCar() else { error = "Not connected"; return }
        var opened = false
        await working("Reading the car's fault codes") {
            phase = .checking("Reading fault codes …")
            do {
                let mechanic = Mechanic(diag: diag, car: car, log: flow.log)
                let check = try await mechanic.healthCheck { phase = .checking($0) }
                let provider = settings.provider
                let conversation = Conversation(
                    vin: car.vin, started: .now, model: model(for: provider) ?? "", carContext: check.contextJSON,
                    messages: [Mechanic.ownerMessage(Mechanic.firstQuestion, provider: provider)], provider: provider)
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

    /// Has the mechanic answer the owner message the conversation ends with, on the conversation's provider:
    /// Anthropic's on the API key, OpenAI's on the ChatGPT plan. Streams its text into `streaming` and its reads and
    /// lookups into `activity`, then records the turn with what its requests used and its activity. A stop, and the
    /// plan's usage limit, keep the text streamed so far; an error keeps the conversation as it was before the answer
    /// and records the error. A token OpenAI refuses is renewed before the sign-in is given up. Either way the
    /// conversation is saved, never holds a tool call without its result, and is ready for the next message, also when
    /// the turn could not start.
    private func runTurn(effort: String) async {
        guard var conversation else { return }
        defer { phase = .ready }
        // The provider the messages are shaped for, which is the picked one: the picker is off while a turn runs.
        let provider = conversation.provider
        guard case let (diag, car)? = connectedCar() else { error = "Not connected"; return }
        guard let model = model(for: provider) else { error = "Pick a model in Settings"; return }
        // Anthropic's key; a turn on the plan asks the sign-in for a token before each request instead.
        guard let key = provider == .anthropic ? Keychain.apiKey() : "" else {
            error = "No API key: enter one in Settings"
            return
        }
        await working("Answering with the AI mechanic") {
            error = nil
            phase = .answering
            let mechanic = Mechanic(diag: diag, car: car, log: flow.log)
            mechanic.beginMessage()
            let ownerMessage = conversation.messages.count - 1
            // What the turn's completed requests used, which a stopped or failed turn records too.
            var usage = Usage.zero
            // A tool call, a result or the end of a request came after the last text: the next text starts after a
            // blank line, where the saved answer starts another bubble.
            var textBroken = false
            // `run` holds its `inout` across awaits, so it works on a copy that goes back only once it returns.
            var messages = conversation.messages
            // The turn's OpenAI client, which learns the models that refuse web search.
            var openAI: OpenAIClient?
            do {
                let client: any ModelClient
                switch provider {
                case .anthropic:
                    client = ClaudeClient(transport: URLSessionTransport(), apiKey: key, log: flow.log)
                case .openai:
                    // A token for each request, renewed when it expires: a turn may outlive one.
                    let session = self.session
                    let made = OpenAIClient(
                        transport: URLSessionTransport(url: Self.responsesURL),
                        tokenProvider: { try await session.validAccessToken() }, log: flow.log,
                        webSearchUnavailable: webSearchUnavailable)
                    openAI = made
                    client = made
                }
                let web: Mechanic.WebTools = provider == .anthropic ? .searchAndFetch : .search
                let turn = try await client.run(
                    messages: &messages, system: Mechanic.systemPrompt(carContext: conversation.carContext, web: web),
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
                            if let line = Self.serverToolLine(block) { activity.append(line) }
                            // A call, a lookup, reasoning, or a whole OpenAI message.
                            if block["type"]?.string != "text" { textBroken = true }
                        case .finished:
                            textBroken = true  // the end of one request of the turn, not of the turn
                        }
                    },
                    // Also the usage a plan limit carries, before it is thrown.
                    onUsage: { usage = usage + $0 })
                conversation.messages = messages
                conversation.turns.append(TurnRecord(
                    messageIndex: ownerMessage, usage: turn.usage, rounds: turn.rounds, refused: turn.refused,
                    truncated: turn.truncated, stoppedAtRoundCap: turn.stoppedAtRoundCap, stopped: false, model: model,
                    activity: activity, provider: provider, webSearchDropped: turn.webSearchDropped))
            } catch is CancellationError {
                keepStreamedText(in: &conversation)
                conversation.turns.append(TurnRecord(
                    messageIndex: ownerMessage, usage: usage, rounds: 0, refused: false, truncated: false,
                    stoppedAtRoundCap: false, stopped: true, model: model, activity: activity, provider: provider))
            } catch {
                var error = error
                // A refused token is renewed first: a new sign-in is asked for only when renewing fails for good.
                if case OpenAIError.unauthorized = error {
                    do { _ = try await session.renew() } catch let renewal { error = renewal }
                }
                let text: String
                switch error {
                case ClaudeError.api(_, let type, let message): text = "API error (\(type)): \(message)"
                case ClaudeError.badToolInput, OpenAIError.badToolInput:
                    text = "The model sent an unreadable tool request; ask again"
                case ClaudeError.network(let message): text = "No connection to Anthropic: \(message)"
                case OpenAIError.planLimit("subscription_sharing_usage_limit_exceeded", _, _):
                    planLimited = true
                    keepStreamedText(in: &conversation)  // as on Stop
                    text = "Usage limit reached"
                case OpenAIError.planLimit("subscription_sharing_usage_unavailable", _, _):
                    text = "ChatGPT couldn't check your plan's usage; try again in a moment"
                case OpenAIError.api(403?, "subscription_sharing_user_not_eligible", let message, _):
                    text = Self.notEligible(message)  // not tried again: the account, not the request, is refused
                case OpenAIError.api(_, let code, let message, _), OpenAIError.planLimit(let code, let message, _):
                    text = "API error (\(code)): \(message)"
                case OpenAIError.unauthorized:
                    text = "OpenAI refused the request; try again"  // renewed: Try again sends the new token
                case OpenAIError.network(let message), SignInError.network(let message):
                    text = "No connection to OpenAI: \(message)"
                case SignInError.signedOut:
                    // The session dropped the sign-in (a renewal that failed for good among the ways), or a sign-in
                    // that completed meanwhile replaced it.
                    chatGPT = session.account
                    text = chatGPT == nil
                        ? "Sign in to ChatGPT again in Settings" : "The ChatGPT sign-in changed; try again"
                case SignInError.planNotGranted:
                    chatGPT = session.account  // kept, as the settings show it, without plan usage
                    text = "Vynscope may not use your ChatGPT plan; sign in again and allow plan usage"
                default:
                    text = Flow.describe(error)
                }
                self.error = text
                conversation.turns.append(TurnRecord(
                    messageIndex: ownerMessage, usage: usage, rounds: 0, refused: false, truncated: false,
                    stoppedAtRoundCap: false, stopped: false, model: model, error: text, activity: activity,
                    provider: provider))
            }
            if let openAI {
                // The model refused web search during the turn: a stopped or failed turn says so too.
                if !webSearchUnavailable.contains(model), openAI.webSearchUnavailable.contains(model) {
                    conversation.turns[conversation.turns.count - 1].webSearchDropped = true
                }
                webSearchUnavailable = openAI.webSearchUnavailable
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

    /// Adds the text streamed so far to `conversation` as an answer, as a stop and the plan's usage limit keep it.
    private func keepStreamedText(in conversation: inout Conversation) {
        let text = streaming.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            conversation.messages.append(Self.assistantTextMessage(text, provider: conversation.provider))
        }
    }

    /// What an account OpenAI does not let share its plan with other apps (`subscription_sharing_user_not_eligible`)
    /// is told, with OpenAI's `message`.
    private static func notEligible(_ message: String) -> String {
        "This ChatGPT account may not use its plan in other apps (\(message)). "
            + "Pick Anthropic in Settings to use the mechanic."
    }

    /// The model a turn with `provider` runs on: the Anthropic model, or the OpenAI model picked from the account's
    /// list, nil until one is.
    private func model(for provider: Provider) -> String? {
        switch provider {
        case .anthropic: settings.model
        case .openai: settings.openAIModel
        }
    }

    /// The text a stop or the plan's usage limit keeps, as an assistant message of `provider`'s shape: one text block,
    /// or a `message` item with one `output_text` part, which the chat shows where a plain-string content would show
    /// nothing.
    private static func assistantTextMessage(_ text: String, provider: Provider) -> JSON {
        switch provider {
        case .anthropic:
            .object([
                "role": .string("assistant"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ])
        case .openai:
            .object([
                "type": .string("message"), "role": .string("assistant"),
                "content": .array([.object([
                    "type": .string("output_text"), "text": .string(text), "annotations": .array([]),
                ])]),
            ])
        }
    }
}
