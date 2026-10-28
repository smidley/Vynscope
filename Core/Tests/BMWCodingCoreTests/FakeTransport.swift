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
