import Foundation
import Testing
@testable import BMWCodingCore

func userText(_ text: String) -> JSON {
    .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
}
func request() -> ClaudeRequest { ClaudeRequest(model: "m", effort: "medium", system: [], tools: [], messages: [userText("q")]) }

@Test func bodyAndHeadersFollowTheSpec() async throws {
    let transport = FakeTransport([(200, [:], textStream("hi"))])
    let client = ClaudeClient(transport: transport, apiKey: "sk-ant-secret", log: Log())
    let request = ClaudeRequest(model: "claude-opus-5-5", effort: "high",
        system: [.object(["type": .string("text"), "text": .string("rules")]), .object(["type": .string("text"), "text": .string("car")])],
        tools: [.object(["name": .string("get_vehicle"), "strict": .bool(true)])],
        messages: [.object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("hello")])])])])
    _ = try await client.send(request) { _ in }
    let call = try #require(transport.calls.first)
    #expect(call.headers["x-api-key"] == "sk-ant-secret")
    #expect(call.headers["anthropic-version"] == "2026-10-21")
    #expect(call.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
    #expect(call.headers["content-type"] == "application/json")
    #expect(call.body["max_tokens"]?.int == 16000 && call.body["stream"]?.bool == true)
    #expect(call.body["fallbacks"]?.string == "default")
    #expect(call.body["output_config"]?["effort"]?.string == "high")
    #expect(call.body["tool_choice"] == nil && call.body["thinking"] == nil && call.body["temperature"] == nil)
    #expect(call.body["system"]?.array?[0]["cache_control"] == nil)
    #expect(call.body["system"]?.array?[1]["cache_control"] == .object(["type": .string("ephemeral")]))
    #expect(call.body["messages"]?.array?[0]["content"]?.array?[0]["cache_control"] == .object(["type": .string("ephemeral")]))
}
@Test func streamsTextAndReportsUsage() async throws {
    let transport = FakeTransport([(200, [:], textStream("Hello owner", input: 300, cached: 250, output: 12))])
    var seen = ""
    let message = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).send(request()) {
        if case .text(let t) = $0 { seen += t }
    }
    #expect(seen == "Hello owner" && message.stopReason == "end_turn")
    #expect(message.usage.cacheReadInputTokens == 250 && message.usage.outputTokens == 12)
}
@Test func retriesRateLimitOverloadAndServerErrors() async throws {
    var slept: [Duration] = []
    let transport = FakeTransport([
        (429, ["retry-after": "5"], "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}"),
        (529, [:], "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"),
        (200, [:], textStream("ok"))])
    let client = ClaudeClient(transport: transport, apiKey: "k", log: Log()) { slept.append($0) }
    _ = try await client.send(request()) { _ in }
    #expect(slept == [.seconds(5), .seconds(2)])
    #expect(transport.calls.count == 3)
}
@Test func givesUpAfterThreeTries() async throws {
    let overloaded = (529, [String: String](), "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}")
    let transport = FakeTransport([overloaded, overloaded, overloaded])
    let client = ClaudeClient(transport: transport, apiKey: "k", log: Log()) { _ in }
    await #expect(throws: ClaudeError.api(status: 529, type: "overloaded_error", message: "Overloaded")) {
        try await client.send(request()) { _ in }
    }
    #expect(transport.calls.count == 3)
}
@Test func authErrorIsNotRetriedAndKeyIsNeverLogged() async throws {
    let transport = FakeTransport([(401, [:], "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}")])
    let log = Log()
    let client = ClaudeClient(transport: transport, apiKey: "sk-ant-secret", log: log)
    await #expect(throws: ClaudeError.api(status: 401, type: "authentication_error", message: "invalid x-api-key")) {
        try await client.send(request()) { _ in }
    }
    #expect(transport.calls.count == 1)
    #expect(log.entries.contains { $0.text == "ai: error 401 authentication_error: invalid x-api-key" })
    #expect(!log.entries.contains { $0.text.contains("sk-ant-secret") })
}
@Test func errorEventBeforeContentIsRetriedAfterContentIsThrown() async throws {
    let early = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
    let late = textStream("partial").replacingOccurrences(of: "event: message_delta", with: early + "event: message_delta")
    let transport = FakeTransport([(200, [:], early), (200, [:], textStream("fine")), (200, [:], late)])
    let log = Log()
    let client = ClaudeClient(transport: transport, apiKey: "k", log: log) { _ in }
    #expect(try await client.send(request()) { _ in }.content.first?["text"]?.string == "fine")
    await #expect(throws: ClaudeError.api(status: nil, type: "overloaded_error", message: "Overloaded")) {
        try await client.send(request()) { _ in }
    }
    #expect(log.entries.last?.text == "ai: error - overloaded_error: Overloaded")
}
@Test func aStreamThatEndsBeforeMessageStopThrows() async throws {
    let cut = textStream("partial").components(separatedBy: "event: content_block_stop")[0]
    let transport = FakeTransport([(200, [:], cut)])
    let log = Log()
    let client = ClaudeClient(transport: transport, apiKey: "k", log: log) { _ in }
    await #expect(throws: ClaudeError.network("the stream ended before message_stop")) {
        try await client.send(request()) { _ in }
    }
    #expect(transport.calls.count == 1)
    #expect(log.entries.last?.text == "ai: network error: the stream ended before message_stop")
}
@Test func aCancelledSendThrowsCancellationNotAConnectionError() async throws {
    let cut = textStream("partial").components(separatedBy: "event: content_block_stop")[0]
    let transport = FakeTransport([(200, [:], cut)])
    let client = ClaudeClient(transport: transport, apiKey: "k", log: Log())
    let task = Task { try await client.send(request()) { _ in } }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
@Test func transportLinesKeepBlankLinesAndDropLineEndings() async throws {
    func lines(_ text: String) async throws -> [String] {
        let bytes = AsyncStream<UInt8> { c in
            for byte in Array(text.utf8) { c.yield(byte) }
            c.finish()
        }
        var lines: [String] = []
        for try await line in URLSessionTransport.lines(bytes) { lines.append(line) }
        return lines
    }
    #expect(try await lines("event: a\ndata: 1\n\nevent: b\r\ndata: 2\r\n\r\n") == ["event: a", "data: 1", "", "event: b", "data: 2", ""])
    #expect(try await lines(#"{"type":"error"}"#) == [#"{"type":"error"}"#])  // an error body has no final line feed
}

@Test func runsToolsAndEchoesContentVerbatim() async throws {
    let transport = FakeTransport([
        (200, [:], toolUseStream(id: "toolu_1", name: "read_faults", input: #"{"module":"40"}"#, output: 50)),
        (200, [:], textStream("Two faults.", input: 900, cached: 800, output: 20))])
    var messages: [JSON] = [userText("What is wrong?")]
    var calls: [ToolCall] = []
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "claude-opus-5-5", effort: "medium",
        runTool: { calls.append($0); return ToolResult(#"{"faults":[]}"#) }, onUpdate: { _ in })
    #expect(calls == [ToolCall(id: "toolu_1", name: "read_faults", input: .object(["module": .string("40")]))])
    #expect(messages.count == 4)
    #expect(messages[1]["content"]?.array?.contains { $0["type"]?.string == "thinking" } == true)
    #expect(messages[2] == .object(["role": .string("user"), "content": .array([.object([
        "type": .string("tool_result"), "tool_use_id": .string("toolu_1"), "content": .string(#"{"faults":[]}"#)])])]))
    #expect(transport.calls[1].body["messages"]?.array?.count == 3)
    #expect(turn.rounds == 1 && turn.usage.outputTokens == 70 && turn.usage.cacheReadInputTokens == 800)
}
@Test func toolFailureIsAnErrorResult() async throws {
    let transport = FakeTransport([(200, [:], toolUseStream(id: "t", name: "read_value", input: #"{"module":"40","did":"3000"}"#)), (200, [:], textStream("ok"))])
    var messages: [JSON] = [userText("q")]
    _ = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ToolResult("module 40 did not answer", isError: true) }, onUpdate: { _ in })
    #expect(messages[2]["content"]?.array?.first?["is_error"]?.bool == true)
}
@Test func stopsAtTheRoundCapWithToolChoiceNone() async throws {
    var script = (0..<13).map { _ in (200, [String: String](), toolUseStream(id: "t", name: "get_vehicle", input: "{}")) }
    script.append((200, [:], textStream("Here is what I have.")))
    let transport = FakeTransport(script)
    var messages: [JSON] = [userText("q")]
    var ran = 0
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ran += 1; return ToolResult("{}") }, onUpdate: { _ in })
    #expect(ran == 12 && turn.rounds == 13 && turn.stoppedAtRoundCap)
    let last = try #require(transport.calls.last)
    #expect(last.body["tool_choice"] == .object(["type": .string("none")]))
    #expect(ClaudeClient.roundCapResult == "Tool limit for this message reached; answer with what you already have")
    #expect(messages[messages.count - 2]["content"]?.array?.first?["content"]?.string == ClaudeClient.roundCapResult)
    #expect(messages.last?["content"]?.array?.first?["text"]?.string == "Here is what I have.")
}
@Test func refusalRunsNoToolAndDropsItsCall() async throws {
    let transport = FakeTransport([(200, [:], refusalStream(text: "I cannot"))])
    var messages: [JSON] = [userText("q")]
    var ran = false
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ran = true; return ToolResult("") }, onUpdate: { _ in })
    #expect(!ran && turn.refused)
    #expect(messages.count == 2 && messages[1]["content"]?.array?.count == 1)
    #expect(messages[1]["content"]?.array?.first?["type"]?.string == "text")
}
@Test func pauseTurnIsResentUnchanged() async throws {
    let transport = FakeTransport([(200, [:], pauseStream()), (200, [:], textStream("done"))])
    var messages: [JSON] = [userText("q")]
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ToolResult("") }, onUpdate: { _ in })
    #expect(transport.calls[1].body["messages"]?.array?.count == 2)
    #expect(transport.calls[1].body["messages"]?.array?.last?["role"]?.string == "assistant")
    #expect(turn.rounds == 1 && messages.count == 3)
}
@Test func truncatedToolInputRunsNothing() async throws {
    let stream = toolUseStream(id: "t", name: "get_vehicle", input: "{}").replacingOccurrences(of: "\"stop_reason\":\"tool_use\"", with: "\"stop_reason\":\"max_tokens\"")
    let transport = FakeTransport([(200, [:], stream)])
    var messages: [JSON] = [userText("q")]
    var ran = false
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ran = true; return ToolResult("") }, onUpdate: { _ in })
    #expect(!ran && turn.truncated && messages.count == 1)
}
@Test func aFailedTurnLeavesTheMessagesAsTheyWere() async throws {
    let transport = FakeTransport([(200, [:], toolUseStream(id: "t", name: "get_vehicle", input: "{}"))])
    var messages: [JSON] = [userText("q")]
    let before = messages
    struct Boom: Error {}
    await #expect(throws: Boom.self) {
        try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
            messages: &messages, system: [], tools: [], model: "m", effort: "medium",
            runTool: { _ in throw Boom() }, onUpdate: { _ in })
    }
    #expect(messages == before)
}
@Test func echoDropsModelInternalsBeforeAFallback() {
    let text: JSON = .object(["type": .string("text"), "text": .string("a")])
    let thinking: JSON = .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("s")])
    let toolUse: JSON = .object(["type": .string("tool_use"), "id": .string("t"), "name": .string("x"), "input": .object([:])])
    let search: JSON = .object(["type": .string("server_tool_use"), "id": .string("srv"), "name": .string("web_search"), "input": .object([:])])
    let result: JSON = .object(["type": .string("web_search_tool_result"), "tool_use_id": .string("srv"), "content": .array([])])
    let lone: JSON = .object(["type": .string("server_tool_use"), "id": .string("srv2"), "name": .string("web_search"), "input": .object([:])])
    let fallback: JSON = .object(["type": .string("fallback"), "from": .object(["model": .string("a")]), "to": .object(["model": .string("b")])])
    #expect(ClaudeClient.echo([thinking, text, toolUse]) == [thinking, text, toolUse])
    #expect(ClaudeClient.echo([thinking, text, toolUse, search, result, lone, fallback, thinking, text]) == [text, search, result, fallback, thinking, text])
}
@Test func aCallAbandonedAtAFallbackDoesNotRun() async throws {
    let stream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":100,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"read_faults","input":{}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-sonnet-5-5"}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: content_block_start
        data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"b","name":"read_faults","input":{}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":2}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":30}}

        event: message_stop
        data: {"type":"message_stop"}

        """
    let transport = FakeTransport([(200, [:], stream), (200, [:], textStream("done"))])
    var messages: [JSON] = [userText("q")]
    var calls: [ToolCall] = []
    _ = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { calls.append($0); return ToolResult("{}") }, onUpdate: { _ in })
    #expect(calls == [ToolCall(id: "b", name: "read_faults", input: .object([:]))])
    #expect(messages[2]["content"]?.array?.compactMap { $0["tool_use_id"]?.string } == ["b"])
}
@Test(arguments: ["max_tokens", "model_context_window_exceeded"])
func aToolCallCutOffAtTheLimitTruncatesTheTurn(stop: String) async throws {
    // A text block, then a tool call whose input the limit cut off.
    let stream = refusalStream(text: "Reading module 40")
        .replacingOccurrences(of: #""partial_json":"{}""#, with: #""partial_json":"{\"module\": \"4""#)
        .replacingOccurrences(of: #""stop_reason":"refusal""#, with: #""stop_reason":"\#(stop)""#)
    let transport = FakeTransport([(200, [:], stream)])
    var messages: [JSON] = [userText("q")]
    var ran = false
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ran = true; return ToolResult("") }, onUpdate: { _ in })
    #expect(!ran && turn.truncated)
    #expect(messages == [userText("q"), .object(["role": .string("assistant"), "content": .array([
        .object(["type": .string("text"), "text": .string("Reading module 40")])])])])
}
@Test func maxTokensDropsAThinkingBlockCutOffBeforeItsSignature() async throws {
    // A thinking block cut off before its signature, after the text.
    let thinking = """
        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"Next I"}}


        """
    let stream = textStream("The faults are")
        .replacingOccurrences(of: "event: message_delta", with: thinking + "event: message_delta")
        .replacingOccurrences(of: #""stop_reason":"end_turn""#, with: #""stop_reason":"max_tokens""#)
    let transport = FakeTransport([(200, [:], stream)])
    var messages: [JSON] = [userText("q")]
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ToolResult("") }, onUpdate: { _ in })
    #expect(turn.truncated)
    #expect(messages == [userText("q"), .object(["role": .string("assistant"), "content": .array([
        .object(["type": .string("text"), "text": .string("The faults are")])])])])
}
@Test func theCacheMarkerSkipsAThinkingBlock() {
    let text: JSON = .object(["type": .string("text"), "text": .string("Searching")])
    let thinking: JSON = .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("s")])
    let paused: JSON = .object(["role": .string("assistant"), "content": .array([text, thinking])])
    let body = ClaudeClient.body(for: ClaudeRequest(model: "m", effort: "medium", system: [], tools: [],
                                                    messages: [userText("q"), paused]))
    let content = body["messages"]?.array?.last?["content"]?.array
    #expect(content?[0]["cache_control"] == .object(["type": .string("ephemeral")]))
    #expect(content?[1]["cache_control"] == nil)
}
@Test func theRoundCapEndsARunOfPauses() async throws {
    let transport = FakeTransport((0..<13).map { _ in (200, [String: String](), pauseStream()) })
    var messages: [JSON] = [userText("q")]
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ToolResult("") }, onUpdate: { _ in })
    #expect(transport.calls.count == 13 && turn.rounds == 13 && turn.stoppedAtRoundCap)
    #expect(messages == [userText("q")])
}
@Test func everyCompletedRequestReportsItsUsage() async throws {
    let transport = FakeTransport([
        (200, [:], toolUseStream(id: "t", name: "get_vehicle", input: "{}", output: 50)),
        (200, [:], textStream("Done.", input: 900, cached: 800, output: 20))])
    var messages: [JSON] = [userText("q")]
    var usages: [Usage] = []
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ToolResult("{}") }, onUpdate: { _ in }, onUsage: { usages.append($0) })
    try #require(usages.count == 2)
    #expect(usages.map { [$0.inputTokens, $0.outputTokens, $0.cacheReadInputTokens] } == [[100, 50, 0], [900, 20, 800]])
    #expect(turn.usage == usages[0] + usages[1])
    // The second request fails: the first one's usage was reported, and only it.
    let failing = FakeTransport([
        (200, [:], toolUseStream(id: "t", name: "get_vehicle", input: "{}", output: 50)),
        (401, [:], "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}")])
    messages = [userText("q")]
    var reported: [Usage] = []
    await #expect(throws: ClaudeError.self) {
        try await ClaudeClient(transport: failing, apiKey: "k", log: Log()).run(
            messages: &messages, system: [], tools: [], model: "m", effort: "medium",
            runTool: { _ in ToolResult("{}") }, onUpdate: { _ in }, onUsage: { reported.append($0) })
    }
    #expect(reported.map(\.outputTokens) == [50])
}
@Test func aCutAnswerKeepsTheWebLookupsItsCitationsPointTo() async throws {
    // A web search and its result, the text that cites it, then a tool call max_tokens cut off.
    let stream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":100,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv","name":"web_search","input":{}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv","content":[]}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: content_block_start
        data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":"The nozzle is blocked"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":2}

        event: content_block_start
        data: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"t","name":"get_vehicle","input":{}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":3}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":16000}}

        event: message_stop
        data: {"type":"message_stop"}

        """
    let transport = FakeTransport([(200, [:], stream)])
    var messages: [JSON] = [userText("q")]
    var ran = false
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ran = true; return ToolResult("") }, onUpdate: { _ in })
    #expect(!ran && turn.truncated)
    #expect(messages.count == 2 && messages[1]["content"]?.array == [
        .object(["type": .string("server_tool_use"), "id": .string("srv"), "name": .string("web_search"), "input": .object([:])]),
        .object(["type": .string("web_search_tool_result"), "tool_use_id": .string("srv"), "content": .array([])]),
        .object(["type": .string("text"), "text": .string("The nozzle is blocked")])])
}
