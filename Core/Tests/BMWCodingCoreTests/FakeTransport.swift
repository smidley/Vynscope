import Foundation
@testable import BMWCodingCore

/// Answers `post` from a script, one entry per call, in order, and records every call.
final class FakeTransport: Transport {
    struct Call { var body: JSON; var headers: [String: String] }
    private(set) var calls: [Call] = []
    private var script: [(status: Int, headers: [String: String], text: String)]

    init(_ script: [(status: Int, headers: [String: String], text: String)]) { self.script = script }

    func post(body: Data, headers: [String: String]) async throws -> TransportResponse {
        calls.append(Call(body: try JSON.parse(body), headers: headers))
        precondition(!script.isEmpty, "unscripted request")
        let next = script.removeFirst()
        let lines = next.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return TransportResponse(status: next.status, headers: next.headers, lines: AsyncThrowingStream { c in
            for line in lines { c.yield(line) }
            c.finish()
        })
    }
}

/// A minimal end_turn stream with `text` and the given usage.
func textStream(_ text: String, input: Int = 100, cached: Int = 0, output: Int = 10) -> String {
    messageStream([textBlock(0, text)], stop: "end_turn", input: input, cached: cached, output: output)
}

/// A tool_use stream: an empty thinking block with a signature, then one `tool_use` block whose input arrives as the
/// JSON text `input`.
func toolUseStream(id: String, name: String, input: String, output: Int = 10) -> String {
    messageStream([thinkingBlock(0), toolUseBlock(1, id: id, name: name, input: input)], stop: "tool_use", output: output)
}

/// A pause_turn stream with one text block.
func pauseStream() -> String { messageStream([textBlock(0, "Searching")], stop: "pause_turn") }

/// A refusal stream with one text block and one `tool_use` block.
func refusalStream(text: String) -> String {
    messageStream([textBlock(0, text), toolUseBlock(1, id: "t", name: "get_vehicle", input: "{}")], stop: "refusal")
}

/// One message as the Messages API streams it: `message_start` with the input usage, the events of `blocks`, a
/// `message_delta` with `stop` and the cumulative usage, and `message_stop`.
private func messageStream(_ blocks: [String], stop: String, input: Int = 100, cached: Int = 0, output: Int = 10) -> String {
    [event("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cached),"output_tokens":1}}}"#),
     blocks.joined(),
     event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stop)","stop_sequence":null},"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cached),"output_tokens":\#(output)}}"#),
     event("message_stop", #"{"type":"message_stop"}"#)].joined()
}

private func textBlock(_ index: Int, _ text: String) -> String {
    [event("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#),
     event("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":\#(literal(text))}}"#),
     event("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)].joined()
}

private func thinkingBlock(_ index: Int) -> String {
    [event("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"thinking","thinking":""}}"#),
     event("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"signature_delta","signature":"sig"}}"#),
     event("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)].joined()
}

private func toolUseBlock(_ index: Int, id: String, name: String, input: String) -> String {
    [event("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"tool_use","id":\#(literal(id)),"name":\#(literal(name)),"input":{}}}"#),
     event("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"input_json_delta","partial_json":\#(literal(input))}}"#),
     event("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)].joined()
}

private func event(_ name: String, _ data: String) -> String { "event: \(name)\ndata: \(data)\n\n" }

/// `text` as a JSON string, quotes and escapes included.
private func literal(_ text: String) -> String { String(decoding: JSON.string(text).encoded(), as: UTF8.self) }

/// One Responses stream: `response.created`, the events of `items`, and the terminal event with the items as the
/// response's `output` and the usage.
func responsesStream(_ items: [ResponsesItemFixture], end: String = "completed", input: Int = 100, cached: Int = 0,
                     output: Int = 10, reasoning: Int = 0, incompleteReason: String? = nil, listsOutput: Bool = true) -> String {
    let outputs = items.map(\.json).joined(separator: ",")
    let outputField = listsOutput ? #""output":[\#(outputs)],"# : ""  // a ChatGPT-plan stream ended without the list
    let response = { (status: String) in
        #"{"id":"resp_1","object":"response","model":"gpt-6.1-sol","status":"\#(status)",\#(outputField)"incomplete_details":\#(incompleteReason.map { #"{"reason":"\#($0)"}"# } ?? "null"),"usage":{"input_tokens":\#(input),"input_tokens_details":{"cached_tokens":\#(cached)},"output_tokens":\#(output),"output_tokens_details":{"reasoning_tokens":\#(reasoning)},"total_tokens":\#(input + output)}}"#
    }
    return [event("response.created", #"{"type":"response.created","sequence_number":0,"response":\#(response("in_progress"))}"#),
            items.map(\.events).joined(),
            event("response.\(end)", #"{"type":"response.\#(end)","sequence_number":99,"response":\#(response(end))}"#)].joined()
}

/// A Responses stream that fails after `items` with `code` and `message` in `response.failed`.
func responsesFailure(_ items: [ResponsesItemFixture], code: String, message: String) -> String {
    let outputs = items.map(\.json).joined(separator: ",")
    return [event("response.created", #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","object":"response","model":"gpt-6.1-sol","status":"in_progress","output":[],"usage":null}}"#),
            items.map(\.events).joined(),
            event("response.failed", #"{"type":"response.failed","sequence_number":99,"response":{"id":"resp_1","object":"response","model":"gpt-6.1-sol","status":"failed","output":[\#(outputs)],"error":{"code":\#(literal(code)),"message":\#(literal(message))},"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":0},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":105}}}"#)].joined()
}

/// An item of a Responses stream: its events, and its JSON as it appears in the response's output.
struct ResponsesItemFixture { var events: String; var json: String }

/// An assistant message item with one output_text part, `text`, and the `url_citation` annotations given.
func textItem(_ index: Int, _ text: String, citations: [(url: String, title: String)] = []) -> ResponsesItemFixture {
    let id = "msg_\(index)"
    let annotations = citations.map { #"{"type":"url_citation","url":\#(literal($0.url)),"title":\#(literal($0.title)),"start_index":0,"end_index":1}"# }.joined(separator: ",")
    let item = #"{"id":"\#(id)","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":\#(literal(text)),"annotations":[\#(annotations)]}]}"#
    let events = [
        event("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":\#(index),"item":{"id":"\#(id)","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
        event("response.content_part.added", #"{"type":"response.content_part.added","sequence_number":2,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
        event("response.output_text.delta", #"{"type":"response.output_text.delta","sequence_number":3,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"delta":\#(literal(text)),"logprobs":[]}"#),
    ] + citations.map { event("response.output_text.annotation.added", #"{"type":"response.output_text.annotation.added","sequence_number":4,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"annotation_index":0,"annotation":{"type":"url_citation","url":\#(literal($0.url)),"title":\#(literal($0.title)),"start_index":0,"end_index":1}}"#) } + [
        event("response.output_text.done", #"{"type":"response.output_text.done","sequence_number":5,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"text":\#(literal(text)),"logprobs":[]}"#),
        event("response.content_part.done", #"{"type":"response.content_part.done","sequence_number":6,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"part":{"type":"output_text","text":\#(literal(text)),"annotations":[\#(annotations)]}}"#),
        event("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":7,"output_index":\#(index),"item":\#(item)}"#),
    ]
    return ResponsesItemFixture(events: events.joined(), json: item)
}

/// An assistant message item whose one part is a `refusal` saying `text`.
func refusalItem(_ index: Int, _ text: String) -> ResponsesItemFixture {
    let id = "msg_\(index)"
    let item = #"{"id":"\#(id)","type":"message","role":"assistant","status":"completed","content":[{"type":"refusal","refusal":\#(literal(text))}]}"#
    let events = [
        event("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":\#(index),"item":{"id":"\#(id)","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
        event("response.refusal.delta", #"{"type":"response.refusal.delta","sequence_number":2,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"delta":\#(literal(text))}"#),
        event("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":3,"output_index":\#(index),"item":\#(item)}"#),
    ]
    return ResponsesItemFixture(events: events.joined(), json: item)
}

/// A function call item of the `car` namespace whose arguments arrive as the JSON text `arguments`.
func functionCallItem(_ index: Int, callId: String, name: String, arguments: String) -> ResponsesItemFixture {
    let id = "fc_\(index)"
    let item = #"{"id":"\#(id)","type":"function_call","status":"completed","namespace":"car","name":\#(literal(name)),"call_id":\#(literal(callId)),"arguments":\#(literal(arguments))}"#
    let events = [
        event("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":\#(index),"item":{"id":"\#(id)","type":"function_call","status":"in_progress","namespace":"car","name":\#(literal(name)),"call_id":\#(literal(callId)),"arguments":""}}"#),
        event("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","sequence_number":2,"item_id":"\#(id)","output_index":\#(index),"delta":\#(literal(arguments))}"#),
        event("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","sequence_number":3,"item_id":"\#(id)","output_index":\#(index),"arguments":\#(literal(arguments))}"#),
        event("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":4,"output_index":\#(index),"item":\#(item)}"#),
    ]
    return ResponsesItemFixture(events: events.joined(), json: item)
}

/// A reasoning item with encrypted content, as `include: ["reasoning.encrypted_content"]` returns it.
func reasoningItem(_ index: Int) -> ResponsesItemFixture {
    let item = #"{"id":"rs_\#(index)","type":"reasoning","summary":[],"encrypted_content":"gAAAA-opaque"}"#
    let events = [
        event("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":\#(index),"item":{"id":"rs_\#(index)","type":"reasoning","summary":[]}}"#),
        event("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":2,"output_index":\#(index),"item":\#(item)}"#),
    ]
    return ResponsesItemFixture(events: events.joined(), json: item)
}

/// A completed web search call for `query`.
func webSearchItem(_ index: Int, query: String) -> ResponsesItemFixture {
    let item = #"{"id":"ws_\#(index)","type":"web_search_call","status":"completed","action":{"type":"search","query":\#(literal(query))}}"#
    let events = [
        event("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":\#(index),"item":{"id":"ws_\#(index)","type":"web_search_call","status":"in_progress","action":{"type":"search","query":\#(literal(query))}}}"#),
        event("response.web_search_call.in_progress", #"{"type":"response.web_search_call.in_progress","sequence_number":2,"item_id":"ws_\#(index)","output_index":\#(index)}"#),
        event("response.web_search_call.searching", #"{"type":"response.web_search_call.searching","sequence_number":3,"item_id":"ws_\#(index)","output_index":\#(index)}"#),
        event("response.web_search_call.completed", #"{"type":"response.web_search_call.completed","sequence_number":4,"item_id":"ws_\#(index)","output_index":\#(index)}"#),
        event("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":5,"output_index":\#(index),"item":\#(item)}"#),
    ]
    return ResponsesItemFixture(events: events.joined(), json: item)
}

/// Answers `send` from a script, one reply per request, in order, and records every request. A request made while
/// `hold` is set gets its reply only at `release()`, so that a test can keep one call open while it makes another.
final class FakeHTTPTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var script: [HTTPReply]
    var hold = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ script: [HTTPReply]) { self.script = script }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        requests.append(request)
        precondition(!script.isEmpty, "unscripted request")
        let reply = script.removeFirst()
        if hold { await withCheckedContinuation { held.append($0) } }
        return reply
    }

    /// Lets the replies held so far go.
    func release() {
        for request in held { request.resume() }
        held.removeAll()
    }
}

/// A reply with `status`, `body` as UTF-8 and `headers`.
func reply(_ status: Int, _ body: String, headers: [String: String] = [:]) -> HTTPReply {
    HTTPReply(status: status, headers: headers, body: Data(body.utf8))
}
