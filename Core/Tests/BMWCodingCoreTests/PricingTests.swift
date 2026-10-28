import Foundation
import Testing
@testable import BMWCodingCore

@Test func costUsesTheTable() {
    let usage = Usage(inputTokens: 1000, outputTokens: 500, cacheCreationInputTokens: 100, cacheReadInputTokens: 2000, webSearchRequests: 3, webFetchRequests: 0)
    #expect(abs((PriceTable.standard.cost(of: usage, model: "claude-opus-5-5") ?? 0) - 0.0149) < 1e-12)
    #expect(abs((PriceTable.standard.cost(of: usage, model: "claude-haiku-5-5") ?? 0) - 0.0003825) < 1e-12)
    #expect(PriceTable.standard.cost(of: usage, model: "claude-opus-4-8") == nil)
}
