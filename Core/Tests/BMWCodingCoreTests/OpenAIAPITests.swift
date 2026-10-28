import Foundation
import Testing
@testable import BMWCodingCore

/// Feeds a stream's lines through the parser and assembler, collecting the updates.
private func assemble(_ stream: String) throws -> (updates: [StreamUpdate], message: ResponsesMessage) {
    var parser = SSEParser(), assembler = ResponsesAssembler(), updates: [StreamUpdate] = []
    for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
        if let event = parser.feed(String(line)), let update = try assembler.apply(event) { updates.append(update) }
    }
    return (updates, assembler.message())
}

@Test func textStreamsAndTheMessageCarriesItsItemsAndUsage() throws {
    let (updates, message) = try assemble(responsesStream([reasoningItem(0), textItem(1, "Hello owner", citations: [("https://a.example/p", "Page")])], input: 300, cached: 250, output: 12, reasoning: 7))
    #expect(updates.first == .block(try JSON.parse(Data(reasoningItem(0).json.utf8))))
    #expect(updates.contains(.text("Hello owner")))
    #expect(updates.last == .finished)
    #expect(message.status == "completed" && message.output.count == 2)
    #expect(message.output[1]["content"]?.array?[0]["annotations"]?.array?[0]["url"]?.string == "https://a.example/p")
    #expect(message.usage == Usage(inputTokens: 300, outputTokens: 12, cacheCreationInputTokens: 0, cacheReadInputTokens: 250, webSearchRequests: 0, webFetchRequests: 0, reasoningTokens: 7))
}

@Test func aFunctionCallArrivesWholeAndASearchCounts() throws {
    let (updates, message) = try assemble(responsesStream([webSearchItem(0, query: "B1F3E BMW"), functionCallItem(1, callId: "call_1", name: "read_faults", arguments: #"{"module":"40"}"#)]))
    let call = try JSON.parse(Data(functionCallItem(1, callId: "call_1", name: "read_faults", arguments: #"{"module":"40"}"#).json.utf8))
    #expect(updates.contains(.block(call)))
    #expect(message.usage.webSearchRequests == 1)
    #expect(message.output[1]["arguments"]?.string == #"{"module":"40"}"#)
}

@Test func anIncompleteResponseKeepsItsReasonAndText() throws {
    let (_, message) = try assemble(responsesStream([textItem(0, "Half an")], end: "incomplete", incompleteReason: "max_output_tokens"))
    #expect(message.status == "incomplete" && message.incompleteReason == "max_output_tokens")
    #expect(message.output.count == 1)
}

@Test func aFailedResponseThrowsItsCode() throws {
    let planLimit = responsesFailure([textItem(0, "Looking")], code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached")
    #expect(throws: OpenAIError.planLimit(code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached", usage: Usage(inputTokens: 100, outputTokens: 5, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, webSearchRequests: 0, webFetchRequests: 0, reasoningTokens: 0))) { try assemble(planLimit) }
    let other = responsesFailure([], code: "server_error", message: "boom")
    #expect(throws: OpenAIError.api(status: nil, code: "server_error", message: "boom", param: nil)) { try assemble(other) }
}

@Test func anErrorEventThrowsAndAnUnreadableArgumentIsReportedAtTheEnd() throws {
    let errorEvent = "event: error\ndata: {\"type\":\"error\",\"sequence_number\":1,\"code\":\"invalid_request\",\"message\":\"bad\",\"param\":null}\n\n"
    #expect(throws: OpenAIError.api(status: nil, code: "invalid_request", message: "bad", param: nil)) { try assemble(errorEvent) }
    let cutCall = responsesStream([functionCallItem(0, callId: "c", name: "read_faults", arguments: #"{"module":"4"#)])
    #expect(throws: OpenAIError.badToolInput(#"{"module":"4"#)) { try assemble(cutCall) }
    let cutByLimit = responsesStream([functionCallItem(0, callId: "c", name: "read_faults", arguments: #"{"module":"4"#)], end: "incomplete", incompleteReason: "max_output_tokens")
    #expect(try assemble(cutByLimit).message.output[0]["arguments"]?.string == "{}")
}

@Test func anErrorEventWithAPlanCodeIsAPlanLimit() throws {
    let limit = "event: error\ndata: {\"type\":\"error\",\"sequence_number\":1,\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"Usage limit reached\",\"param\":null}\n\n"
    #expect(throws: OpenAIError.planLimit(code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached", usage: .zero)) { try assemble(limit) }
    #expect(OpenAIError.planLimitCodes == ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable"])
}
