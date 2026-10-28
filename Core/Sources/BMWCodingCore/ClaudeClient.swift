import Foundation

/// The seam to the Messages endpoint: one POST, answered with the status, the headers and the body's lines.
public protocol Transport: AnyObject {
    func post(body: Data, headers: [String: String]) async throws -> TransportResponse
}

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
        return TransportResponse(status: http?.statusCode ?? 0, headers: fields, lines: Self.lines(of: bytes))
    }

    /// The lines of `bytes`, split at line feeds with a carriage return before one dropped. Unlike Foundation's
    /// `lines` this keeps blank lines, and a blank line is what ends each Server-Sent Event.
    nonisolated static func lines(of bytes: some AsyncSequence<UInt8, any Error> & Sendable)
        -> AsyncThrowingStream<String, any Error>
    {
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
    /// `output_config.effort`: `low`, `medium` or `high`.
    public var effort: String
    public var system: [JSON]
    public var tools: [JSON]
    public var messages: [JSON]
    /// Sends `tool_choice: {"type": "none"}`, the answer the round cap asks for; otherwise it is left out (auto).
    public var toolChoiceNone: Bool = false
}

/// Talks to the Messages API: one streamed request at a time, with retries, and the mechanic's tool loop over
/// them. Every request and its usage goes to the log; the key never does.
public final class ClaudeClient {
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
    /// the last system block and on the last block of the last message. The markers go on copies, so the stored
    /// conversation stays as the API sent it, every echo is resent byte for byte, and the message marker moves
    /// with the last message.
    public static func body(for request: ClaudeRequest) -> JSON {
        var messages = request.messages
        if case .object(var last)? = messages.last, let content = last["content"]?.array {
            last["content"] = .array(markingLast(content))
            messages[messages.count - 1] = .object(last)
        }
        var body: [String: JSON] = [
            "model": .string(request.model), "max_tokens": .number(16000), "stream": .bool(true),
            "fallbacks": .string("default"), "output_config": .object(["effort": .string(request.effort)]),
            "system": .array(markingLast(request.system)), "tools": .array(request.tools),
            "messages": .array(messages),
        ]
        if request.toolChoiceNone { body["tool_choice"] = .object(["type": .string("none")]) }
        return .object(body)
    }

    /// Sends `request` and streams the answer, giving `onUpdate` each update. Three tries in all: a 429, 500 or
    /// 529, or an `error` event before any content block started, is tried again after 1 s and then 2 s (a 429's
    /// integer `retry-after` instead, at most 30 s). Any other status the API refuses with, an `error` event after
    /// content, and a failure still there at the third try throw `ClaudeError.api`. A stream that ends without
    /// `message_stop` gives the message as far as it got.
    public func send(_ request: ClaudeRequest, onUpdate: (StreamUpdate) -> Void) async throws -> AssistantMessage {
        let body = Self.body(for: request).encoded()
        var tries = 0
        while true {
            tries += 1
            log.note("ai: request \(request.model) effort \(request.effort), \(request.messages.count) messages, \(request.tools.count) tools")
            let response = try await transport.post(body: body, headers: headers)
            var delay = Duration.seconds(tries)
            let reason: String
            if (200..<300).contains(response.status) {
                var parser = SSEParser(), assembler = StreamAssembler()
                do {
                    for try await line in response.lines {
                        guard let event = parser.feed(line), let update = try assembler.apply(event) else { continue }
                        onUpdate(update)
                        if update == .finished { break }
                    }
                    try Task.checkCancellation()  // a cancel ends the stream early: that is a Stop, not an answer
                    let message = assembler.message(), usage = message.usage
                    log.note("ai: \(message.stopReason ?? "none") · in \(usage.inputTokens) · cached \(usage.cacheReadInputTokens) · out \(usage.outputTokens) · searches \(usage.webSearchRequests)")
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

    /// `blocks` with `cache_control: {"type": "ephemeral"}` on the last one.
    private static func markingLast(_ blocks: [JSON]) -> [JSON] {
        guard case .object(var last)? = blocks.last else { return blocks }
        last["cache_control"] = .object(["type": .string("ephemeral")])
        var blocks = blocks
        blocks[blocks.count - 1] = .object(last)
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
