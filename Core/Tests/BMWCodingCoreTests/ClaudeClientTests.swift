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
    #expect(!log.entries.contains { $0.text.contains("sk-ant-secret") })
}
@Test func errorEventBeforeContentIsRetriedAfterContentIsThrown() async throws {
    let early = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
    let late = textStream("partial").replacingOccurrences(of: "event: message_delta", with: early + "event: message_delta")
    let transport = FakeTransport([(200, [:], early), (200, [:], textStream("fine")), (200, [:], late)])
    let client = ClaudeClient(transport: transport, apiKey: "k", log: Log()) { _ in }
    #expect(try await client.send(request()) { _ in }.content.first?["text"]?.string == "fine")
    await #expect(throws: ClaudeError.api(status: nil, type: "overloaded_error", message: "Overloaded")) {
        try await client.send(request()) { _ in }
    }
}
@Test func aCancelledSendThrowsCancellationInsteadOfAPartialAnswer() async throws {
    let transport = FakeTransport([(200, [:], textStream("hi"))])
    let client = ClaudeClient(transport: transport, apiKey: "k", log: Log())
    let task = Task { try await client.send(request()) { _ in } }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
@Test func transportLinesKeepBlankLinesAndDropLineEndings() async throws {
    let bytes = AsyncThrowingStream<UInt8, any Error> { c in
        for byte in "event: ping\r\ndata: {}\n\n{\"type\":\"error\"}".utf8 { c.yield(byte) }
        c.finish()
    }
    var lines: [String] = []
    for try await line in URLSessionTransport.lines(of: bytes) { lines.append(line) }
    #expect(lines == ["event: ping", "data: {}", "", "{\"type\":\"error\"}"])
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
    #expect(messages[messages.count - 2]["content"]?.array?.first?["content"]?.string == "Tool limit for this message reached; answer with what you already have")
    #expect(messages.last?["content"]?.array?.first?["text"]?.string == "Here is what I have.")
}
@Test func refusalRunsNoToolAndKeepsOnlyText() async throws {
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
