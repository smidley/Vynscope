import Foundation

/// What requests to the Messages API used, in tokens and in server-side tool calls, for the usage line and the
/// cost estimate. A turn's usage is the sum of its requests'.
public struct Usage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int
    public var webSearchRequests: Int
    public var webFetchRequests: Int

    public static let zero = Usage(
        inputTokens: 0, outputTokens: 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
        webSearchRequests: 0, webFetchRequests: 0)

    public init(
        inputTokens: Int, outputTokens: Int, cacheCreationInputTokens: Int, cacheReadInputTokens: Int,
        webSearchRequests: Int, webFetchRequests: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.webSearchRequests = webSearchRequests
        self.webFetchRequests = webFetchRequests
    }

    /// The usage object of a Messages response or stream event: `input_tokens`, `output_tokens`,
    /// `cache_creation_input_tokens`, `cache_read_input_tokens` and, inside `server_tool_use`, `web_search_requests`
    /// and `web_fetch_requests`. A key it lacks is 0.
    public init(_ json: JSON) {
        self = .zero
        update(from: json)
    }

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(
            inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
            cacheCreationInputTokens: a.cacheCreationInputTokens + b.cacheCreationInputTokens,
            cacheReadInputTokens: a.cacheReadInputTokens + b.cacheReadInputTokens,
            webSearchRequests: a.webSearchRequests + b.webSearchRequests,
            webFetchRequests: a.webFetchRequests + b.webFetchRequests)
    }

    /// Replaces the fields `json` carries and keeps the others: the usage of a `message_delta` is cumulative, but may
    /// leave out what did not change.
    mutating func update(from json: JSON?) {
        inputTokens = json?["input_tokens"]?.int ?? inputTokens
        outputTokens = json?["output_tokens"]?.int ?? outputTokens
        cacheCreationInputTokens = json?["cache_creation_input_tokens"]?.int ?? cacheCreationInputTokens
        cacheReadInputTokens = json?["cache_read_input_tokens"]?.int ?? cacheReadInputTokens
        webSearchRequests = json?["server_tool_use"]?["web_search_requests"]?.int ?? webSearchRequests
        webFetchRequests = json?["server_tool_use"]?["web_fetch_requests"]?.int ?? webFetchRequests
    }
}

/// One reply of the model, as a stream put it together.
public struct AssistantMessage: Equatable, Sendable {
    public var id: String
    public var model: String
    /// The content blocks as the API sent them, to be sent back unchanged in the next request.
    public var content: [JSON]
    /// Why the model stopped (`end_turn`, `tool_use`, `pause_turn`, `refusal`, ...); `nil` until the stream says.
    public var stopReason: String?
    /// What the API says about a `refusal`; `nil` when it says nothing.
    public var stopDetails: JSON?
    public var usage: Usage
}

public enum ClaudeError: Error, Equatable {
    /// The API refused or failed the request. `status` is the HTTP status, or `nil` for an `error` event inside a
    /// stream that had begun with 200; `type` and `message` are the API's own, as in `overloaded_error`.
    case api(status: Int?, type: String, message: String)
    /// A tool call whose input arrived as text that is not a JSON object; the text.
    case badToolInput(String)
    /// The request got no answer, or the answer broke off: what the system says went wrong.
    case network(String)
}

/// One event of a Server-Sent Events stream.
public struct SSEEvent: Equatable, Sendable {
    /// The `event:` of the event, `message` when it has none.
    public var name: String
    /// The `data:` lines of the event, joined with a line feed.
    public var data: String
}

/// Cuts a Server-Sent Events stream into events, a line at a time.
public struct SSEParser {
    private var name: String?
    private var data: [String] = []

    public init() {}

    /// Takes the next line of the stream, without its line ending. A blank line completes the event, which is
    /// returned; any other line returns `nil`. `event:` sets the name, each `data:` adds a line of data, and the rest
    /// is ignored: comments (lines starting with `:`), `id:`, `retry:`. A blank line with no `event:` or `data:`
    /// before it returns `nil`.
    public mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            guard name != nil || !data.isEmpty else { return nil }
            defer { name = nil; data = [] }
            return SSEEvent(name: name ?? "message", data: data.joined(separator: "\n"))
        }
        let field = line.prefix { $0 != ":" }
        var value = line.dropFirst(field.count + 1)  // nothing, when the line has no colon
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break  // a comment (no field name), `id`, `retry`, and any field to come
        }
        return nil
    }
}

/// What an event adds for the screen.
public enum StreamUpdate: Equatable, Sendable {
    /// The next piece of the answer's text.
    case text(String)
    /// A content block that is complete, as it will be sent back: a tool call, with its input, is one. A tool call
    /// whose input is unreadable comes with `input` `{}`, and `message_stop` reports it.
    case block(JSON)
    /// The message is complete.
    case finished
}

/// Puts the events of one Messages stream together into the message they describe, block by block.
public struct StreamAssembler {
    private var id = ""
    private var model = ""
    private var stopReason: String?
    private var stopDetails: JSON?
    private var usage = Usage.zero
    /// The content blocks that have started, by the index the stream gives them.
    private var blocks: [Int: [String: JSON]] = [:]
    /// The input of each `tool_use` and `server_tool_use` block that is still streaming, as the text of JSON that
    /// arrives in pieces, by block index.
    private var partialInput: [Int: String] = [:]
    /// The input text of the first tool call whose input is not a JSON object, which reads as `{}` in its block.
    private var badInput: String?

    public init() {}

    /// Applies the next event of the stream. A `text_delta` returns `.text`, a `content_block_stop` the finished
    /// `.block`, `message_stop` `.finished`; any other event returns `nil`, `ping`, an event this does not know (a
    /// later API version may add some) and a delta or stop for a block that never started among them. Throws
    /// `ClaudeError.api(status: nil, ...)` for an `error` event. A tool call whose input is not a JSON object when
    /// its block stops gets `{}` instead; `message_stop` then throws `ClaudeError.badToolInput` with the first such
    /// text, unless the message stopped at a limit (`max_tokens`, `model_context_window_exceeded`), which cut that
    /// input off.
    public mutating func apply(_ event: SSEEvent) throws -> StreamUpdate? {
        // ponytail: data that is not JSON reads as nothing, so a corrupt event is skipped without a word. Throw
        // instead if a stream is ever seen arriving garbled.
        let body = (try? JSON.parse(Data(event.data.utf8))) ?? .null
        switch event.name {
        case "message_start":
            let message = body["message"]
            id = message?["id"]?.string ?? ""
            model = message?["model"]?.string ?? ""
            usage = Usage(message?["usage"] ?? .null)
        case "content_block_start":
            guard let index = body["index"]?.int, let block = body["content_block"]?.object else { return nil }
            blocks[index] = block
            if let type = block["type"]?.string, type == "tool_use" || type == "server_tool_use" {
                partialInput[index] = ""
            }
        case "content_block_delta":
            guard let index = body["index"]?.int, blocks[index] != nil, let delta = body["delta"] else { return nil }
            switch delta["type"]?.string {
            case "text_delta":
                let text = delta["text"]?.string ?? ""
                append(text, to: "text", ofBlock: index)
                return .text(text)
            case "input_json_delta":
                partialInput[index]?.append(delta["partial_json"]?.string ?? "")
            case "thinking_delta":
                append(delta["thinking"]?.string ?? "", to: "thinking", ofBlock: index)
            case "signature_delta":
                blocks[index]?["signature"] = delta["signature"]
            case "citations_delta":
                if let citation = delta["citation"] {
                    let before = blocks[index]?["citations"]?.array ?? []  // none yet, or `null`
                    blocks[index]?["citations"] = .array(before + [citation])
                }
            default:
                break  // a delta this does not know
            }
        case "content_block_stop":
            guard let index = body["index"]?.int, var block = blocks[index] else { return nil }
            if let text = partialInput.removeValue(forKey: index) {
                if text.isEmpty {
                    block["input"] = .object([:])  // a tool called without arguments
                } else if case .object(let input)? = try? JSON.parse(Data(text.utf8)) {
                    block["input"] = .object(input)
                } else {
                    block["input"] = .object([:])
                    badInput = badInput ?? text
                }
                blocks[index] = block
            }
            return .block(.object(block))
        case "message_delta":
            if let reason = body["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let details = body["delta"]?["stop_details"], details != .null { stopDetails = details }
            usage.update(from: body["usage"])
        case "message_stop":
            if let text = badInput, !["max_tokens", "model_context_window_exceeded"].contains(stopReason) {
                throw ClaudeError.badToolInput(text)
            }
            return .finished
        case "error":
            let error = body["error"]
            throw ClaudeError.api(
                status: nil, type: error?["type"]?.string ?? "error", message: error?["message"]?.string ?? event.data)
        default:
            break  // ping, and any event a later API version adds
        }
        return nil
    }

    /// The message as far as the events applied have built it, `message_stop` or not; a block still streaming is in
    /// it as it stands.
    public func message() -> AssistantMessage {
        AssistantMessage(
            id: id, model: model, content: blocks.sorted { $0.key < $1.key }.map { .object($0.value) },
            stopReason: stopReason, stopDetails: stopDetails, usage: usage)
    }

    /// Adds `text` to the string at `key` in the block at `index`.
    private mutating func append(_ text: String, to key: String, ofBlock index: Int) {
        let before = blocks[index]?[key]?.string ?? ""
        blocks[index]?[key] = .string(before + text)
    }
}
