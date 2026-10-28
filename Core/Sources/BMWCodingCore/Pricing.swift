import Foundation

/// What each model costs, in dollars per million tokens, for the estimate under an answer. It is data, so that a price
/// that changes is edited, not coded.
public struct PriceTable: Codable, Equatable, Sendable {
    /// By model name, as the API names it.
    public var prices: [String: Price]

    public struct Price: Codable, Equatable, Sendable {
        public var input: Double
        public var output: Double
        /// For a token read from the prompt cache.
        public var cacheRead: Double
    }

    /// The prices to start from.
    public static let standard = PriceTable(prices: [
        "claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.20),
        "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.20),
        "claude-haiku-5-5": Price(input: 0.10, output: 0.50, cacheRead: 0.01),
    ])

    /// The estimated cost in dollars of `usage` on `model`; `nil` for a model that is not in the table. A token written
    /// to the cache costs 1.25 times an input token. Web searches and fetches are not priced.
    public func cost(of usage: Usage, model: String) -> Double? {
        guard let price = prices[model] else { return nil }
        // ponytail: the cache-write premium is the default cache's 1.25 for every model, and web searches cost nothing
        // here, so an estimate falls short by what they cost. Give `Price` a field for either when that matters.
        let microdollars = Double(usage.inputTokens) * price.input
            + Double(usage.cacheCreationInputTokens) * 1.25 * price.input
            + Double(usage.cacheReadInputTokens) * price.cacheRead
            + Double(usage.outputTokens) * price.output
        return microdollars / 1_000_000
    }
}
