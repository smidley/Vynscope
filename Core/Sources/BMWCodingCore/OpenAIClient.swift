import Foundation

/// One request to the Responses API, before `OpenAIClient.body(for:)` makes it a body.
public struct OpenAIRequest: Equatable, Sendable {
    public var model: String
    /// Sent as `reasoning.effort`.
    public var effort: String
    public var instructions: String
    /// The mechanic's tools as `Mechanic.tools` declares them; those with an `input_schema` are sent as the functions
    /// of the `car` namespace, and the Messages API's server tools are left out.
    public var tools: [JSON]
    /// Adds the built-in `web_search` tool.
    public var webSearch: Bool
    /// The whole conversation as Responses input items: nothing is stored between requests.
    public var input: [JSON]
    /// Sends `tool_choice: "none"`, the answer the round cap asks for; otherwise it is left out (auto).
    public var toolChoiceNone: Bool = false
}

/// Talks to the Responses API on the owner's ChatGPT plan: one streamed request at a time, with retries, and the
/// mechanic's tool loop over them. Every request and its usage goes to the log; the access token never does.
public final class OpenAIClient {
    /// Tool rounds per owner message.
    public static let roundCap = ClaudeClient.roundCap
    /// What each tool call past the round cap gets as its result instead of running.
    public static let roundCapResult = ClaudeClient.roundCapResult
    /// What the instructions end with for a model that takes no web search.
    public static let noWebSentence =
        "Web search is not available in this conversation: when a question needs a lookup, say so instead of guessing."

    /// The models that refused web search on this account, which are asked without it.
    public private(set) var webSearchUnavailable: Set<String>

    private let transport: any Transport
    private let headers: [String: String]
    private let log: Log
    private let sleep: (Duration) async throws -> Void

    /// `webSearchUnavailable` is the models already known to refuse web search, which the app carries from one client
    /// to the next.
    public init(
        transport: any Transport, accessToken: String, log: Log, webSearchUnavailable: Set<String> = [],
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.headers = [
            "authorization": "Bearer \(accessToken)", "content-type": "application/json", "accept": "text/event-stream",
        ]
        self.log = log
        self.webSearchUnavailable = webSearchUnavailable
        self.sleep = sleep
    }

    /// The body for `request`: streamed and not stored, its reasoning returned encrypted so that it can go back with
    /// the next round, the mechanic's tools as the strict functions of the `car` namespace, then web search when on.
    public static func body(for request: OpenAIRequest) -> JSON {
        let functions: [JSON] = request.tools.compactMap { tool in
            guard let schema = tool["input_schema"] else { return nil }
            return .object([
                "type": .string("function"), "name": tool["name"] ?? .null, "description": tool["description"] ?? .null,
                "parameters": schema, "strict": .bool(true),
            ])
        }
        var tools: [JSON] = [.object([
            "type": .string("namespace"), "name": .string("car"),
            "description": .string("The connected car and the app's data about it, read through the app"),
            "tools": .array(functions),
        ])]
        if request.webSearch { tools.append(.object(["type": .string("web_search")])) }
        var body: [String: JSON] = [
            "model": .string(request.model), "instructions": .string(request.instructions),
            "input": .array(request.input), "stream": .bool(true), "store": .bool(false),
            "reasoning": .object(["effort": .string(request.effort)]),
            "include": .array([.string("reasoning.encrypted_content")]), "tools": .array(tools),
        ]
        if request.toolChoiceNone { body["tool_choice"] = .string("none") }
        return .object(body)
    }

    /// Sends `request` and streams the answer, giving `onUpdate` each update. Three tries in all: a 429, 500, 502 or
    /// 503, and a stream that fails for `subscription_sharing_usage_unavailable` before any output item, are tried
    /// again after 1 s and then 2 s (a 429's integer `retry-after` instead, at most 30 s). A 429 for the plan's usage
    /// limit throws `.planLimit` at once and a 401 `.unauthorized`; any other status the API refuses with, and a
    /// failure still there at the third try, throw `.api`, or `.planLimit` when the code is one of the plan's two. A
    /// stream that ends before `response.completed`, or a connection lost, throws `.network` and is not tried again.
    /// Each is logged as thrown.
    public func send(_ request: OpenAIRequest, onUpdate: (StreamUpdate) -> Void) async throws -> ResponsesMessage {
        let error: OpenAIError
        do {
            return try await sendWithRetries(request, onUpdate: onUpdate)
        } catch let thrown as OpenAIError {
            error = thrown
        } catch ClaudeError.network(let text) {
            error = .network(text)  // the transport's lost connection
        }
        switch error {
        case .api(let status, let code, let message, _):
            log.note("ai: error \(status.map(String.init) ?? "-") \(code): \(message)")
            if status == 401 { throw OpenAIError.unauthorized }
        case .planLimit(let code, let message, _): log.note("ai: plan limit \(code): \(message)")
        case .network(let message): log.note("ai: network error: \(message)")
        case .unauthorized, .badToolInput: break
        }
        throw error
    }

    /// `send` without the note of the error it throws: the tries and the waits between them.
    private func sendWithRetries(
        _ request: OpenAIRequest, onUpdate: (StreamUpdate) -> Void
    ) async throws -> ResponsesMessage {
        let body = Self.body(for: request).encoded()
        let tools = request.tools.filter { $0["input_schema"] != nil }.count + (request.webSearch ? 1 : 0)
        var tries = 0
        while true {
            tries += 1
            log.note(
                "ai: request \(request.model) effort \(request.effort), \(request.input.count) items, \(tools) tools")
            let response = try await transport.post(body: body, headers: headers)
            var delay = Duration.seconds(tries)
            let reason: String
            if (200..<300).contains(response.status) {
                var parser = SSEParser(), assembler = ResponsesAssembler(), finished = false
                do {
                    for try await line in response.lines {
                        guard let event = parser.feed(line), let update = try assembler.apply(event) else { continue }
                        onUpdate(update)
                        if update == .finished { finished = true; break }
                    }
                    try Task.checkCancellation()  // a cancel ends the stream early: that is a Stop, not an answer
                    // A half-built response would put a function call without its arguments into the conversation.
                    guard finished else { throw OpenAIError.network("the stream ended before response.completed") }
                    let message = assembler.message(), usage = message.usage
                    log.note(
                        "ai: \(message.status) · in \(usage.inputTokens) · cached \(usage.cacheReadInputTokens) · "
                            + "out \(usage.outputTokens) · reasoning \(usage.reasoningTokens) · "
                            + "searches \(usage.webSearchRequests)")
                    return message
                } catch OpenAIError.planLimit("subscription_sharing_usage_unavailable", _, _)
                    where tries < 3 && assembler.message().output.isEmpty {
                    reason = "subscription_sharing_usage_unavailable"  // nothing of the answer was shown yet
                }
            } else {
                let error = try await Self.apiError(response)
                // The plan's usage limit is not a rate limit: asking again would only meet it again.
                if response.status == 429, case .planLimit("subscription_sharing_usage_limit_exceeded", _, _) = error {
                    throw error
                }
                guard [429, 500, 502, 503].contains(response.status), tries < 3 else { throw error }
                if response.status == 429, let seconds = response.headers["retry-after"].flatMap({ UInt($0) }) {
                    delay = .seconds(min(seconds, 30))
                }
                reason = "\(response.status)"
            }
            log.note("ai: retry \(tries) after \(reason)")
            try await self.sleep(delay)
        }
    }

    /// Runs one owner message, which `messages` already ends with, to its answer: sends, runs the functions the model
    /// calls through `runTool` and sends their outputs, for up to `roundCap` rounds. `messages` are Responses input
    /// items and `system` the prompt's text blocks, which become the instructions. A model that refuses web search is
    /// asked the same round again without it, and is never asked with it again. `onUsage` is told the usage of each
    /// request as it completes, and the usage a plan limit carries before it is thrown. `messages` takes every item
    /// of the turn only when it returns: when `send` or `runTool` throws, it is left as it was, so it never holds a
    /// call without its output.
    public func run(
        messages: inout [JSON], system: [JSON], tools: [JSON], model: String, effort: String,
        runTool: (ToolCall) async throws -> ToolResult, onUpdate: (StreamUpdate) -> Void, onUsage: (Usage) -> Void
    ) async throws -> Turn {
        let prompt = system.compactMap { $0["text"]?.string }
        var conversation = messages
        var turn = Turn(usage: .zero, rounds: 0, refused: false, truncated: false, stoppedAtRoundCap: false)
        var toolChoiceNone = false
        while true {
            let webSearch = !webSearchUnavailable.contains(model)
            let request = OpenAIRequest(
                model: model, effort: effort,
                instructions: (prompt + (webSearch ? [] : [Self.noWebSentence])).joined(separator: "\n\n"),
                tools: tools, webSearch: webSearch, input: conversation, toolChoiceNone: toolChoiceNone)
            let message: ResponsesMessage
            do {
                message = try await send(request, onUpdate: onUpdate)
            } catch let error as OpenAIError {
                switch error {
                case .api(400?, "subscription_sharing_unsupported_capability", let text, let param)
                    where webSearch && [param ?? "", text].contains(where: { $0.contains("web_search") }):
                    webSearchUnavailable.insert(model)
                    log.note("ai: web search unavailable on \(model), asking again without it")
                    turn.webSearchDropped = true
                    continue
                case .planLimit(_, _, let usage):
                    onUsage(usage)
                default:
                    break
                }
                throw error
            }
            onUsage(message.usage)
            turn.usage = turn.usage + message.usage
            // An answer a limit cut off, or a refusal, goes back as its message items only, and none of its calls
            // runs: a half-made call must never be sent back.
            let answer = message.output.filter { $0["type"]?.string == "message" }
            let truncated = message.status == "incomplete"
            let refused = !truncated
                && answer.last?["content"]?.array?.contains { $0["type"]?.string == "refusal" } == true
            conversation += truncated || refused ? answer : message.output
            if truncated || refused || toolChoiceNone {
                turn.truncated = truncated
                turn.refused = refused
                turn.stoppedAtRoundCap = toolChoiceNone
                break
            }
            let calls = message.output.filter { $0["type"]?.string == "function_call" }
            if calls.isEmpty { break }
            turn.rounds += 1
            if turn.rounds > Self.roundCap {
                let limit = ToolResult(Self.roundCapResult, isError: true)
                conversation += calls.map { Self.outputItem(limit, for: $0) }
                toolChoiceNone = true
            } else {
                for call in calls {
                    let input = (try? JSON.parse(Data((call["arguments"]?.string ?? "").utf8))) ?? .null
                    let result = if input.object != nil {
                        try await runTool(
                            ToolCall(id: call["call_id"]?.string ?? "", name: call["name"]?.string ?? "", input: input))
                    } else {
                        ToolResult("tool input was not an object", isError: true)
                    }
                    conversation.append(Self.outputItem(result, for: call))
                }
            }
        }
        messages = conversation
        return turn
    }

    /// The `function_call_output` item answering the `function_call` item `call` with `result`.
    private static func outputItem(_ result: ToolResult, for call: JSON) -> JSON {
        .object([
            "type": .string("function_call_output"), "call_id": call["call_id"] ?? .null, "namespace": .string("car"),
            "name": call["name"] ?? .null,
            "output": .string(result.isError ? "Error: " + result.content : result.content),
        ])
    }

    /// The error a response that is not 2xx carries: the code (its type when the code is null), message and param of
    /// its `{"error": {...}}` body, or `http_<status>` and the body's first 200 characters when the body is not that.
    /// Either of the plan's codes, at any status, is `.planLimit`, without usage: the app has one shape to match.
    private static func apiError(_ response: TransportResponse) async throws -> OpenAIError {
        var lines: [String] = []
        for try await line in response.lines { lines.append(line) }
        let text = lines.joined(separator: "\n")
        let error = (try? JSON.parse(Data(text.utf8)))?["error"]
        guard let code = error?["code"]?.string ?? error?["type"]?.string, let message = error?["message"]?.string
        else {
            return .api(
                status: response.status, code: "http_\(response.status)", message: String(text.prefix(200)), param: nil)
        }
        if ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable"].contains(code) {
            return .planLimit(code: code, message: message, usage: .zero)
        }
        return .api(status: response.status, code: code, message: message, param: error?["param"]?.string)
    }
}
