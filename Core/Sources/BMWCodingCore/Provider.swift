/// The AI service the mechanic talks to. Each has its own API and its own credentials, and a car has one conversation
/// with each; the raw value is how the settings and the conversation files name it.
public nonisolated enum Provider: String, Codable, Equatable, Sendable, CaseIterable {
    case anthropic
    case openai

    /// The name the settings show for it.
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }
}
