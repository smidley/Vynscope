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
