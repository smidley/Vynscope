import Foundation
import Testing
@testable import BMWCodingCore

func ownerItem(_ text: String) -> JSON {
    .object(["type": .string("message"), "role": .string("user"), "content": .array([.object(["type": .string("input_text"), "text": .string(text)])])])
}
func openAIRequest(_ items: [JSON] = [ownerItem("q")], web: Bool = true) -> OpenAIRequest {
    OpenAIRequest(model: "gpt-6.1-sol", effort: "medium", instructions: "rules", tools: Mechanic.tools, webSearch: web, input: items)
}
func errorBody(_ code: String, _ message: String, param: String? = nil) -> String {
    #"{"error":{"type":"invalid_request_error","code":\#(literalJSON(code)),"message":\#(literalJSON(message)),"param":\#(param.map(literalJSON) ?? "null")}}"#
}
func literalJSON(_ text: String) -> String { String(decoding: JSON.string(text).encoded(), as: UTF8.self) }

@Test func bodyAndHeadersFollowTheSignInWithChatGPTRules() async throws {
    let transport = FakeTransport([(200, [:], responsesStream([textItem(0, "hi")]))])
    let client = OpenAIClient(transport: transport, accessToken: "eyJ-access", log: Log())
    _ = try await client.send(openAIRequest()) { _ in }
    let call = try #require(transport.calls.first)
    #expect(call.headers["authorization"] == "Bearer eyJ-access" && call.headers["x-api-key"] == nil)
    #expect(call.headers["content-type"] == "application/json" && call.headers["accept"] == "text/event-stream")
    let body = call.body
    #expect(body["model"]?.string == "gpt-6.1-sol" && body["instructions"]?.string == "rules")
    #expect(body["stream"]?.bool == true && body["store"]?.bool == false)
    #expect(body["reasoning"]?["effort"]?.string == "medium")
    #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
    #expect(body["input"]?.array?.count == 1 && body["input"]?.array?[0]["role"]?.string == "user")
    for key in ["max_output_tokens", "temperature", "top_p", "truncation", "metadata", "user", "safety_identifier", "previous_response_id", "tool_choice", "prompt_cache_retention", "background", "conversation", "max_tool_calls"] {
        #expect(body[key] == nil, "\(key) must be omitted")
    }
    let tools = try #require(body["tools"]?.array)
    #expect(tools.count == 2)
    #expect(tools[0]["type"]?.string == "namespace" && tools[0]["name"]?.string == "car")
    let functions = try #require(tools[0]["tools"]?.array)
    #expect(functions.count == 6 && functions.allSatisfy { $0["type"]?.string == "function" && $0["strict"]?.bool == true })
    #expect(functions[1]["name"]?.string == "read_faults")
    #expect(functions[1]["parameters"] == Mechanic.tools[1]["input_schema"] && functions[1]["input_schema"] == nil)
    #expect(tools[1] == .object(["type": .string("web_search")]))
    #expect(OpenAIClient.body(for: openAIRequest(web: false))["tools"]?.array?.count == 1)
    var capped = openAIRequest(); capped.toolChoiceNone = true
    #expect(OpenAIClient.body(for: capped)["tool_choice"]?.string == "none")
}

@Test func retriesServerErrorsAndStopsAtThePlanLimit() async throws {
    var waits: [Duration] = []
    let transport = FakeTransport([
        (500, [:], errorBody("server_error", "boom")), (503, [:], errorBody("subscription_sharing_usage_unavailable", "later")),
        (200, [:], responsesStream([textItem(0, "ok")])),
    ])
    let client = OpenAIClient(transport: transport, accessToken: "t", log: Log()) { waits.append($0) }
    let message = try await client.send(openAIRequest()) { _ in }
    #expect(message.output.count == 1 && transport.calls.count == 3 && waits == [.seconds(1), .seconds(2)])

    let limited = FakeTransport([(429, ["retry-after": "20"], errorBody("subscription_sharing_usage_limit_exceeded", "Usage limit reached"))])
    let limitedClient = OpenAIClient(transport: limited, accessToken: "t", log: Log())
    await #expect(throws: OpenAIError.planLimit(code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached", usage: .zero)) {
        try await limitedClient.send(openAIRequest()) { _ in }
    }
    #expect(limited.calls.count == 1)
}

@Test func unauthorizedIsNotRetriedAndTheTokenIsNeverLogged() async throws {
    let log = Log()
    let transport = FakeTransport([(401, [:], errorBody("invalid_token", "The token is invalid"))])
    let client = OpenAIClient(transport: transport, accessToken: "eyJ-secret-token", log: log)
    await #expect(throws: OpenAIError.unauthorized) { try await client.send(openAIRequest()) { _ in } }
    #expect(transport.calls.count == 1)
    #expect(log.entries.contains { $0.text == "ai: error 401 invalid_token: The token is invalid" })
    #expect(!log.entries.contains { $0.text.contains("eyJ-secret-token") })
}

@Test func theToolLoopRunsCallsAndKeepsEveryItem() async throws {
    let transport = FakeTransport([
        (200, [:], responsesStream([reasoningItem(0), functionCallItem(1, callId: "call_1", name: "read_faults", arguments: #"{"module":"40"}"#)], input: 100, output: 20)),
        (200, [:], responsesStream([textItem(0, "No faults in BDC")], input: 300, output: 15)),
    ])
    let client = OpenAIClient(transport: transport, accessToken: "t", log: Log())
    var items = [ownerItem("q")], calls: [ToolCall] = [], usages: [Usage] = []
    let turn = try await client.run(messages: &items, system: [.object(["type": .string("text"), "text": .string("rules")]), .object(["type": .string("text"), "text": .string("car")])], tools: Mechanic.tools, model: "gpt-6.1-sol", effort: "high",
        runTool: { call in calls.append(call); return ToolResult("none stored") }, onUpdate: { _ in }, onUsage: { usages.append($0) })
    #expect(calls == [ToolCall(id: "call_1", name: "read_faults", input: .object(["module": .string("40")]))])
    #expect(turn.rounds == 1 && turn.usage.inputTokens == 400 && usages.count == 2)
    #expect(items.count == 5)  // owner, reasoning, function_call, function_call_output, assistant message
    #expect(items[1]["type"]?.string == "reasoning" && items[1]["encrypted_content"]?.string == "gAAAA-opaque")
    #expect(items[3] == .object(["type": .string("function_call_output"), "call_id": .string("call_1"), "namespace": .string("car"), "name": .string("read_faults"), "output": .string("none stored")]))
    #expect(items[4]["type"]?.string == "message" && items[4]["role"]?.string == "assistant")
    let second = try #require(transport.calls.last)
    #expect(second.body["instructions"]?.string == "rules\n\ncar")
    #expect(second.body["input"]?.array?.count == 4)  // the whole history, reasoning included, no previous_response_id
}

@Test func aFailingToolAnswersWithAnErrorOutput() async throws {
    let transport = FakeTransport([
        (200, [:], responsesStream([functionCallItem(0, callId: "c", name: "read_value", arguments: #"{"module":"40","did":"zz"}"#)])),
        (200, [:], responsesStream([textItem(0, "Could not read")])),
    ])
    var items = [ownerItem("q")]
    _ = try await OpenAIClient(transport: transport, accessToken: "t", log: Log()).run(messages: &items, system: [], tools: Mechanic.tools, model: "m", effort: "low",
        runTool: { _ in ToolResult("did must be four hex digits", isError: true) }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(items[2]["output"]?.string == "Error: did must be four hex digits")
}

@Test func theToolLoopStopsAtTheRoundCapWithToolChoiceNone() async throws {
    var script: [(status: Int, headers: [String: String], text: String)] = []
    for round in 0...OpenAIClient.roundCap { script.append((200, [:], responsesStream([functionCallItem(0, callId: "c\(round)", name: "get_vehicle", arguments: "{}")]))) }
    script.append((200, [:], responsesStream([textItem(0, "Here is what I have")])))
    let transport = FakeTransport(script)
    var items = [ownerItem("q")], ran = 0
    let turn = try await OpenAIClient(transport: transport, accessToken: "t", log: Log()).run(messages: &items, system: [], tools: Mechanic.tools, model: "m", effort: "low",
        runTool: { _ in ran += 1; return ToolResult("{}") }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(ran == OpenAIClient.roundCap && turn.stoppedAtRoundCap && turn.rounds == OpenAIClient.roundCap + 1)
    #expect(transport.calls.last?.body["tool_choice"]?.string == "none")
    #expect(items[items.count - 2]["output"]?.string == "Error: " + OpenAIClient.roundCapResult)
}

@Test func anIncompleteAnswerKeepsOnlyItsTextAndRunsNothing() async throws {
    let transport = FakeTransport([(200, [:], responsesStream([textItem(0, "Half an"), functionCallItem(1, callId: "c", name: "get_vehicle", arguments: "{}")], end: "incomplete", incompleteReason: "max_output_tokens"))])
    var items = [ownerItem("q")], ran = false
    let turn = try await OpenAIClient(transport: transport, accessToken: "t", log: Log()).run(messages: &items, system: [], tools: Mechanic.tools, model: "m", effort: "low",
        runTool: { _ in ran = true; return ToolResult("") }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(!ran && turn.truncated && items.count == 2 && items[1]["type"]?.string == "message")
}

@Test func aPlanLimitMidTurnLeavesTheConversationAsItWasAndReportsTheUsage() async throws {
    let transport = FakeTransport([
        (200, [:], responsesStream([functionCallItem(0, callId: "c", name: "get_vehicle", arguments: "{}")], input: 100, output: 20)),
        (200, [:], responsesFailure([textItem(0, "Looking")], code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached")),
    ])
    var items = [ownerItem("q")], usages: [Usage] = []
    let client = OpenAIClient(transport: transport, accessToken: "t", log: Log())
    await #expect(throws: OpenAIError.planLimit(code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached", usage: Usage(inputTokens: 100, outputTokens: 5, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, webSearchRequests: 0, webFetchRequests: 0, reasoningTokens: 0))) {
        try await client.run(messages: &items, system: [], tools: Mechanic.tools, model: "m", effort: "low", runTool: { _ in ToolResult("{}") }, onUpdate: { _ in }, onUsage: { usages.append($0) })
    }
    #expect(items == [ownerItem("q")] && usages.map(\.outputTokens) == [20, 5])
}

@Test func aModelWithoutWebSearchGetsTheRequestAgainWithoutIt() async throws {
    let log = Log()
    let transport = FakeTransport([
        (400, [:], errorBody("subscription_sharing_unsupported_capability", "web_search is not available for this model", param: "tools[1]")),
        (200, [:], responsesStream([textItem(0, "From the car data")])),
        (200, [:], responsesStream([textItem(0, "Still from the car data")])),
    ])
    let client = OpenAIClient(transport: transport, accessToken: "t", log: log)
    var items = [ownerItem("q")]
    let turn = try await client.run(messages: &items, system: [.object(["type": .string("text"), "text": .string("rules")])], tools: Mechanic.tools, model: "gpt-6.1-sol", effort: "low", runTool: { _ in ToolResult("") }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(turn.webSearchDropped && client.webSearchUnavailable == ["gpt-6.1-sol"])
    #expect(transport.calls[0].body["tools"]?.array?.count == 2 && transport.calls[1].body["tools"]?.array?.count == 1)
    #expect(transport.calls[1].body["instructions"]?.string == "rules\n\n" + OpenAIClient.noWebSentence)
    #expect(log.entries.contains { $0.text == "ai: web search unavailable on gpt-6.1-sol, asking again without it" })
    items.append(ownerItem("more"))
    let later = try await client.run(messages: &items, system: [.object(["type": .string("text"), "text": .string("rules")])], tools: Mechanic.tools, model: "gpt-6.1-sol", effort: "low", runTool: { _ in ToolResult("") }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(!later.webSearchDropped && transport.calls[2].body["tools"]?.array?.count == 1)

    let other = FakeTransport([(400, [:], errorBody("subscription_sharing_unsupported_capability", "model not available", param: "model"))])
    var again = [ownerItem("q")]
    await #expect(throws: OpenAIError.api(status: 400, code: "subscription_sharing_unsupported_capability", message: "model not available", param: "model")) {
        try await OpenAIClient(transport: other, accessToken: "t", log: Log()).run(messages: &again, system: [], tools: Mechanic.tools, model: "m", effort: "low", runTool: { _ in ToolResult("") }, onUpdate: { _ in }, onUsage: { _ in })
    }
    #expect(other.calls.count == 1)
}

@Test func aStreamThatEndsBeforeCompletionThrowsNetwork() async throws {
    let cut = "event: response.created\ndata: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"r\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
    let transport = FakeTransport([(200, [:], cut)])
    await #expect(throws: OpenAIError.network("the stream ended before response.completed")) {
        try await OpenAIClient(transport: transport, accessToken: "t", log: Log()).send(openAIRequest()) { _ in }
    }
}
