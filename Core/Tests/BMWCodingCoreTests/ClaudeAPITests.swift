import Testing
@testable import BMWCodingCore

func assemble(_ text: String) throws -> (AssistantMessage, [StreamUpdate]) {
    var parser = SSEParser(), assembler = StreamAssembler(), updates: [StreamUpdate] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let event = parser.feed(String(line)) else { continue }
        if let update = try assembler.apply(event) { updates.append(update) }
    }
    return (assembler.message(), updates)
}

@Test func sseParserJoinsDataAndIgnoresComments() {
    var p = SSEParser()
    #expect(p.feed(": keep-alive") == nil)
    #expect(p.feed("event: ping") == nil)
    #expect(p.feed("data: {\"a\":1") == nil)
    #expect(p.feed("data: }") == nil)
    #expect(p.feed("") == SSEEvent(name: "ping", data: "{\"a\":1\n}"))
    #expect(p.feed("") == nil)
}
@Test func assemblesTextToolUseThinkingAndUsage() throws {
    let stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":472,"cache_creation_input_tokens":10,"cache_read_input_tokens":400,"output_tokens":2}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig1"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: ping
    data: {"type":"ping"}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"read that."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: content_block_start
    data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_faults","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"module\\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" \\"40\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":2}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"input_tokens":472,"cache_creation_input_tokens":10,"cache_read_input_tokens":400,"output_tokens":89}}

    event: message_stop
    data: {"type":"message_stop"}

    """
    let (message, updates) = try assemble(stream)
    #expect(message.id == "msg_1" && message.model == "claude-opus-5-5" && message.stopReason == "tool_use")
    #expect(message.usage == Usage(inputTokens: 472, outputTokens: 89, cacheCreationInputTokens: 10,
                                   cacheReadInputTokens: 400, webSearchRequests: 0, webFetchRequests: 0))
    #expect(message.content[0] == .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig1")]))
    #expect(message.content[1] == .object(["type": .string("text"), "text": .string("Let me read that.")]))
    #expect(message.content[2]["input"] == .object(["module": .string("40")]))
    #expect(updates.contains(.text("Let me ")) && updates.contains(.text("read that.")))
    #expect(updates.last == .finished)
    #expect(updates.filter { if case .block = $0 { true } else { false } }.count == 3)
}
@Test func assemblesServerToolUseResultsAndCitations() throws {
    let stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":10,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":\\"B1F3E BMW G26\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","title":"Camera washer","url":"https://example.com/a","encrypted_content":"EqgfCio","page_age":null}]}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: content_block_start
    data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"The nozzle"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://example.com/a","title":"Camera washer","encrypted_index":"Eo8B","cited_text":"the washer nozzle"}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"future_delta","x":1}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":2}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":10682,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":510,"server_tool_use":{"web_search_requests":1}}}

    event: message_stop
    data: {"type":"message_stop"}

    """
    let (message, _) = try assemble(stream)
    #expect(message.content[0]["input"]?["query"]?.string == "B1F3E BMW G26")
    #expect(message.content[1]["content"]?.array?.first?["encrypted_content"]?.string == "EqgfCio")
    #expect(message.content[2]["citations"]?.array?.count == 1)
    #expect(message.content[2]["citations"]?.array?.first?["url"]?.string == "https://example.com/a")
    #expect(message.usage.webSearchRequests == 1 && message.usage.inputTokens == 10682)
}
@Test func errorEventThrowsAndBadToolInputThrows() throws {
    let error = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
    #expect(throws: ClaudeError.api(status: nil, type: "overloaded_error", message: "Overloaded")) { try assemble(error) }
    let bad = """
    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_value","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"module\\": "}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    """
    #expect(throws: ClaudeError.badToolInput("{\"module\": ")) { try assemble(bad) }
}
@Test func eventsForABlockThatNeverStartedAreIgnored() throws {
    var assembler = StreamAssembler()
    let delta = SSEEvent(name: "content_block_delta", data: #"{"type":"content_block_delta","index":7,"delta":{"type":"text_delta","text":"x"}}"#)
    let stop = SSEEvent(name: "content_block_stop", data: #"{"type":"content_block_stop","index":7}"#)
    #expect(try assembler.apply(delta) == nil)
    #expect(try assembler.apply(stop) == nil)
    #expect(assembler.message().content.isEmpty)
}
@Test func aStreamCutOffBeforeMessageStopStillMakesAMessage() throws {
    let cut = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_3","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":50,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The cam"}}

    """
    let (message, updates) = try assemble(cut)
    #expect(message.id == "msg_3" && message.stopReason == nil && message.usage.inputTokens == 50)
    #expect(message.content == [.object(["type": .string("text"), "text": .string("The cam")])])
    #expect(!updates.contains(.finished))
}
@Test func usageReadsItsKeysAndAddsFieldWise() {
    let a = Usage(.object(["input_tokens": .number(1), "output_tokens": .number(2), "cache_creation_input_tokens": .number(3),
        "cache_read_input_tokens": .number(4),
        "server_tool_use": .object(["web_search_requests": .number(5), "web_fetch_requests": .number(6)])]))
    #expect(a == Usage(inputTokens: 1, outputTokens: 2, cacheCreationInputTokens: 3, cacheReadInputTokens: 4,
                       webSearchRequests: 5, webFetchRequests: 6))
    #expect(Usage(.object([:])) == .zero)
    let b = Usage(inputTokens: 10, outputTokens: 20, cacheCreationInputTokens: 30, cacheReadInputTokens: 40,
                  webSearchRequests: 50, webFetchRequests: 60)
    #expect(a + b == Usage(inputTokens: 11, outputTokens: 22, cacheCreationInputTokens: 33, cacheReadInputTokens: 44,
                           webSearchRequests: 55, webFetchRequests: 66))
}
