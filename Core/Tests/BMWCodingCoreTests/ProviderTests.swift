import Testing
@testable import BMWCodingCore

@Test func providersHaveNamesAndRawValues() {
    #expect(Provider.anthropic.rawValue == "anthropic" && Provider.openai.rawValue == "openai")
    #expect(Provider.anthropic.displayName == "Anthropic" && Provider.openai.displayName == "OpenAI")
    #expect(Provider.allCases == [.anthropic, .openai])
}
