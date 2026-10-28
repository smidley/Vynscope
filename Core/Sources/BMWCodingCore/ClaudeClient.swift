import Foundation

/// The seam to the Messages endpoint: one POST, answered with the status, the headers and the body's lines.
public protocol Transport: AnyObject {
    func post(body: Data, headers: [String: String]) async throws -> TransportResponse
}

/// What a `Transport` post answers.
public struct TransportResponse {
    public var status: Int
    /// By lower-cased header name.
    public var headers: [String: String]
    /// The body, a line at a time, without line endings; blank lines included.
    public var lines: AsyncThrowingStream<String, any Error>
}

/// `POST https://api.anthropic.com/v1/messages` with `URLSession`.
public final class URLSessionTransport: Transport {
    public init() {}

    public func post(body: Data, headers: [String: String]) async throws -> TransportResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.allHTTPHeaderFields = headers
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await URLSession.shared.bytes(for: request) } catch { throw Self.mapped(error) }
        let http = response as? HTTPURLResponse
        var fields: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] { fields["\(name)".lowercased()] = "\(value)" }
        return TransportResponse(status: http?.statusCode ?? 0, headers: fields, lines: Self.lines(bytes))
    }

    /// The lines of `bytes`, split at line feeds with a carriage return before one dropped. Unlike Foundation's
    /// `lines` this keeps blank lines, and a blank line is what ends each Server-Sent Event.
    nonisolated static func lines<S: AsyncSequence & Sendable>(_ bytes: S) -> AsyncThrowingStream<String, any Error>
    where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        guard byte == UInt8(ascii: "\n") else { line.append(byte); continue }
                        if line.last == UInt8(ascii: "\r") { line.removeLast() }
                        continuation.yield(String(decoding: line, as: UTF8.self))
                        line.removeAll()
                    }
                    if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }  // the reader stopped: close the connection
        }
    }

    /// A `URLError` as `ClaudeError.network`, except a cancel, which is the task's own `CancellationError`, so
    /// that Stop reads as Stop and not as a lost connection.
    nonisolated private static func mapped(_ error: any Error) -> any Error {
        guard let error = error as? URLError else { return error }
        return error.code == .cancelled ? CancellationError() : ClaudeError.network(error.localizedDescription)
    }
}

/// One request to the Messages API, before `ClaudeClient.body(for:)` makes it a body.
public struct ClaudeRequest: Equatable, Sendable {
    public var model: String
    /// Sent as `output_config.effort`.
    public var effort: String
    public var system: [JSON]
    public var tools: [JSON]
    public var messages: [JSON]
    /// Sends `tool_choice: {"type": "none"}`, the answer the round cap asks for; otherwise it is left out (auto).
    public var toolChoiceNone: Bool = false
}

/// A tool the model called: the `id` its result answers, the tool's name and its input object.
public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var input: JSON
}

/// What a tool answers the model; a tool that fails in the ordinary way answers with `isError` instead of throwing.
public struct ToolResult: Equatable, Sendable {
    public var content: String
    public var isError: Bool

    public init(_ content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

/// How one owner message went: the usage of all its requests, the tool rounds, and how it ended when that was not
/// an ordinary answer.
public struct Turn: Equatable, Sendable {
    public var usage: Usage
    /// Tool rounds and `pause_turn` resumptions.
    public var rounds: Int
    /// The model declined; what it said is kept as text.
    public var refused: Bool
    /// `max_tokens` cut the answer off; only its text was kept, and none of its tool calls ran.
    public var truncated: Bool
    /// The round cap was reached: after tool rounds the model was asked to answer without tools; after pauses the
    /// paused answer was dropped.
    public var stoppedAtRoundCap: Bool
}

/// Talks to the Messages API: one streamed request at a time, with retries, and the mechanic's tool loop over
/// them. Every request and its usage goes to the log; the key never does.
public final class ClaudeClient {
    /// Tool rounds and pauses per owner message.
    public static let roundCap = 12

    private let transport: any Transport
    private let headers: [String: String]
    private let log: Log
    private let sleep: (Duration) async throws -> Void

    public init(
        transport: any Transport, apiKey: String, log: Log,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.headers = [
            "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2026-10-21",
            "anthropic-beta": "server-side-fallback-2026-07-01", "accept": "text/event-stream",
        ]
        self.log = log
        self.sleep = sleep
    }

    /// The body for `request`: streamed, at most 16000 tokens, the server-side fallback on, and a cache marker on
    /// the last system block and on the last block of the last message that can carry one. The markers go on
    /// copies, so the stored conversation stays as the API sent it, every echo is resent byte for byte, and the
    /// message marker moves with the last message.
    public static func body(for request: ClaudeRequest) -> JSON {
        var messages = request.messages
        if case .object(var last)? = messages.last, let content = last["content"]?.array {
            last["content"] = .array(marking(content))
            messages[messages.count - 1] = .object(last)
        }
        var body: [String: JSON] = [
            "model": .string(request.model), "max_tokens": .number(16000), "stream": .bool(true),
            "fallbacks": .string("default"), "output_config": .object(["effort": .string(request.effort)]),
            "system": .array(marking(request.system)), "tools": .array(request.tools),
            "messages": .array(messages),
        ]
        if request.toolChoiceNone { body["tool_choice"] = .object(["type": .string("none")]) }
        return .object(body)
    }

    /// Sends `request` and streams the answer, giving `onUpdate` each update. Three tries in all: a 429, 500 or
    /// 529, or an `error` event before any content block started, is tried again after 1 s and then 2 s (a 429's
    /// integer `retry-after` instead, at most 30 s). Any other status the API refuses with, an `error` event after
    /// content, and a failure still there at the third try throw `ClaudeError.api`; a stream that ends before
    /// `message_stop` throws `ClaudeError.network` and is not tried again.
    public func send(_ request: ClaudeRequest, onUpdate: (StreamUpdate) -> Void) async throws -> AssistantMessage {
        let body = Self.body(for: request).encoded()
        var tries = 0
        while true {
            tries += 1
            log.note(
                "ai: request \(request.model) effort \(request.effort), \(request.messages.count) messages, "
                    + "\(request.tools.count) tools")
            let response = try await transport.post(body: body, headers: headers)
            var delay = Duration.seconds(tries)
            let reason: String
            if (200..<300).contains(response.status) {
                var parser = SSEParser(), assembler = StreamAssembler(), finished = false
                do {
                    for try await line in response.lines {
                        guard let event = parser.feed(line), let update = try assembler.apply(event) else { continue }
                        onUpdate(update)
                        if update == .finished { finished = true; break }
                    }
                    try Task.checkCancellation()  // a cancel ends the stream early: that is a Stop, not an answer
                    // A half-built message would put a tool call without its input, or thinking without its
                    // signature, into the conversation.
                    guard finished else { throw ClaudeError.network("the stream ended before message_stop") }
                    let message = assembler.message(), usage = message.usage
                    log.note(
                        "ai: \(message.stopReason ?? "none") · in \(usage.inputTokens) · cached "
                            + "\(usage.cacheReadInputTokens) · out \(usage.outputTokens) · "
                            + "searches \(usage.webSearchRequests)")
                    return message
                } catch ClaudeError.api(nil, let type, _) where tries < 3 && assembler.message().content.isEmpty {
                    reason = type  // nothing of the answer was shown yet
                }
            } else {
                let error = try await Self.apiError(response)
                guard [429, 500, 529].contains(response.status), tries < 3 else { throw error }
                if response.status == 429, let seconds = response.headers["retry-after"].flatMap({ UInt($0) }) {
                    delay = .seconds(min(seconds, 30))
                }
                reason = "\(response.status)"
            }
            log.note("ai: retry \(tries) after \(reason)")
            try await self.sleep(delay)
        }
    }

    /// Runs one owner message, which `messages` already ends with, to its answer: sends, runs the tools the model
    /// calls through `runTool` and sends their results, and resends a `pause_turn` as it stands, for up to
    /// `roundCap` rounds. `messages` takes every message of the turn only when it returns: when `send` or
    /// `runTool` throws, it is left as it was, so it never holds a tool call without its result.
    public func run(
        messages: inout [JSON], system: [JSON], tools: [JSON], model: String, effort: String,
        runTool: (ToolCall) async throws -> ToolResult, onUpdate: (StreamUpdate) -> Void
    ) async throws -> Turn {
        var conversation = messages
        var turn = Turn(usage: .zero, rounds: 0, refused: false, truncated: false, stoppedAtRoundCap: false)
        var toolChoiceNone = false
        loop: while true {
            let request = ClaudeRequest(
                model: model, effort: effort, system: system, tools: tools, messages: conversation,
                toolChoiceNone: toolChoiceNone)
            let message = try await send(request, onUpdate: onUpdate)
            turn.usage = turn.usage + message.usage
            let followUp = request.messages.contains { $0["role"]?.string == "assistant" }
            if followUp, message.usage.cacheReadInputTokens == 0 { log.note("ai: no cache read on this request") }
            // The rest works from the content as it is sent back, so a call abandoned at a fallback never runs.
            let content = Self.echo(message.content)
            // A refusal, or an answer max_tokens cut off, goes back as its text alone and none of its calls runs: a
            // half-made tool call or thinking block must never be sent back.
            let cut = message.stopReason == "refusal" || message.stopReason == "max_tokens"
            let answer = cut ? content.filter { $0["type"]?.string == "text" } : content
            if !answer.isEmpty { conversation.append(Self.message("assistant", answer)) }
            if cut || toolChoiceNone {
                turn.refused = message.stopReason == "refusal"
                turn.truncated = message.stopReason == "max_tokens"
                turn.stoppedAtRoundCap = toolChoiceNone
                break
            }
            switch message.stopReason {
            case "tool_use":
                turn.rounds += 1
                let calls = content.filter { $0["type"]?.string == "tool_use" }
                var results: [JSON] = []
                if turn.rounds > Self.roundCap {
                    let limit = ToolResult(
                        "Tool limit for this message reached; answer with what you already have", isError: true)
                    results = calls.map { Self.resultBlock(limit, for: $0) }
                    toolChoiceNone = true
                } else {
                    for call in calls {
                        let input = call["input"] ?? .null
                        let result = if input.object != nil {
                            try await runTool(
                                ToolCall(id: call["id"]?.string ?? "", name: call["name"]?.string ?? "", input: input))
                        } else {
                            ToolResult("tool input was not an object", isError: true)
                        }
                        results.append(Self.resultBlock(result, for: call))
                    }
                }
                conversation.append(Self.message("user", results))
            case "pause_turn":
                turn.rounds += 1
                if turn.rounds > Self.roundCap {
                    // The paused answer is one assistant turn however many messages it spans; it goes whole, so
                    // the conversation does not end in an unfinished turn.
                    while conversation.count > messages.count, conversation.last?["role"]?.string == "assistant" {
                        conversation.removeLast()
                    }
                    turn.stoppedAtRoundCap = true
                    break loop
                }
            default:
                break loop
            }
        }
        messages = conversation
        return turn
    }

    /// The assistant `content` as it is sent back. A `fallback` block is where another model took the answer over:
    /// before the last one only the text, and the server tool calls whose results came back with those results,
    /// are kept; the first model's thinking, its own tool calls and anything else are dropped.
    public static func echo(_ content: [JSON]) -> [JSON] {
        guard let fallback = content.lastIndex(where: { $0["type"]?.string == "fallback" }) else { return content }
        let isResult = { (block: JSON) in block["type"]?.string?.hasSuffix("_tool_result") == true }
        let answered = Set(content.filter(isResult).compactMap { $0["tool_use_id"]?.string })
        let asked = Set(
            content[..<fallback].compactMap { $0["type"]?.string == "server_tool_use" ? $0["id"]?.string : nil })
        let kept = content[..<fallback].filter { block in
            switch block["type"]?.string {
            case "text": true
            case "server_tool_use": block["id"]?.string.map(answered.contains) ?? false
            default: isResult(block) && (block["tool_use_id"]?.string.map(asked.contains) ?? false)
            }
        }
        return kept + content[fallback...]
    }

    private static func message(_ role: String, _ content: [JSON]) -> JSON {
        .object(["role": .string(role), "content": .array(content)])
    }

    /// The `tool_result` block answering the `tool_use` block `call`.
    private static func resultBlock(_ result: ToolResult, for call: JSON) -> JSON {
        var block: [String: JSON] = [
            "type": .string("tool_result"), "tool_use_id": .string(call["id"]?.string ?? ""),
            "content": .string(result.content),
        ]
        if result.isError { block["is_error"] = .bool(true) }
        return .object(block)
    }

    /// `blocks` with `cache_control: {"type": "ephemeral"}` on the last one that is not a thinking or `fallback`
    /// block, which the API refuses it on; unchanged when there is none.
    private static func marking(_ blocks: [JSON]) -> [JSON] {
        let refusing: Set = ["thinking", "redacted_thinking", "fallback"]
        guard let index = blocks.lastIndex(where: { !refusing.contains($0["type"]?.string ?? "") }),
              case .object(var block) = blocks[index] else { return blocks }
        block["cache_control"] = .object(["type": .string("ephemeral")])
        var blocks = blocks
        blocks[index] = .object(block)
        return blocks
    }

    /// The error a response that is not 2xx carries: the type and message of its `{"type": "error", "error":
    /// {...}}` body, or `http_<status>` and the body's first 200 characters when the body is not that.
    private static func apiError(_ response: TransportResponse) async throws -> ClaudeError {
        var lines: [String] = []
        for try await line in response.lines { lines.append(line) }
        let text = lines.joined(separator: "\n")
        let error = (try? JSON.parse(Data(text.utf8)))?["error"]
        guard let type = error?["type"]?.string, let message = error?["message"]?.string else {
            return .api(status: response.status, type: "http_\(response.status)", message: String(text.prefix(200)))
        }
        return .api(status: response.status, type: type, message: message)
    }
}
