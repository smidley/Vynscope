import Foundation

/// One chat with the mechanic about one car: the messages as the Messages API takes them, so that the next turn carries
/// on from them, and how each turn went.
public struct Conversation: Codable, Equatable {
    public var vin: String
    public var started: Date
    public var model: String
    /// The health check's findings as JSON text, which the system prompt carries.
    public var carContext: String
    public var messages: [JSON]
    public var turns: [TurnRecord]

    /// `messages` and `turns` are empty unless given, as in a new conversation.
    public init(
        vin: String, started: Date, model: String, carContext: String, messages: [JSON] = [], turns: [TurnRecord] = []
    ) {
        self.vin = vin
        self.started = started
        self.model = model
        self.carContext = carContext
        self.messages = messages
        self.turns = turns
    }

    /// What every turn used, added up.
    public var totalUsage: Usage { turns.reduce(.zero) { $0 + $1.usage } }
}

/// How one owner message went, for the usage line under its answer. `usage`, `rounds`, `refused`, `truncated` and
/// `stoppedAtRoundCap` are those of the `Turn` it ran.
public struct TurnRecord: Codable, Equatable {
    /// The index in `Conversation.messages` of the owner message that started the turn.
    public var messageIndex: Int
    public var usage: Usage
    public var rounds: Int
    public var refused: Bool
    public var truncated: Bool
    public var stoppedAtRoundCap: Bool
    /// The owner stopped the turn.
    public var stopped: Bool
    public var model: String

    public init(
        messageIndex: Int, usage: Usage, rounds: Int, refused: Bool, truncated: Bool, stoppedAtRoundCap: Bool,
        stopped: Bool, model: String
    ) {
        self.messageIndex = messageIndex
        self.usage = usage
        self.rounds = rounds
        self.refused = refused
        self.truncated = truncated
        self.stoppedAtRoundCap = stoppedAtRoundCap
        self.stopped = stopped
        self.model = model
    }
}

/// The folder the conversations live in, one JSON file per car: `Conversations/<vin>.json`. A VIN is letters and
/// digits (`VIN.isValid`), so it is a file name as it is. Dates are written as ISO 8601 text, in whole seconds.
public struct ConversationStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The conversation of the car with this VIN, or `nil` when there is no file or it cannot be decoded, in which case
    /// the next `save` replaces it.
    public func load(vin: String) -> Conversation? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Conversation.self, from: Data(contentsOf: file(vin: vin)))
    }

    /// Writes the conversation to its car's file as pretty-printed JSON with sorted keys, creating the folders on the
    /// way. The file is replaced as a whole, so a crash half-way leaves the old one.
    public func save(_ conversation: Conversation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(conversation).write(to: file(vin: conversation.vin), options: .atomic)
    }

    /// Removes every conversation: the `Conversations` folder. Its being missing is not an error.
    public func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    private var folder: URL { directory.appendingPathComponent("Conversations") }

    private func file(vin: String) -> URL { folder.appendingPathComponent("\(vin).json") }
}

/// The suggested questions that end an answer, which the chat shows as chips.
public enum Chips {
    /// `text` split into its body and the questions of the block that ends it. The block is the line
    /// `Mechanic.suggestedQuestionsMarker`, alone on its line, and one to three lines after it that start with `- `,
    /// with nothing but whitespace after them. The body is the text before the block without trailing whitespace; a
    /// question is its line without the dash. A text that does not end that way is the body as it is, with no
    /// questions.
    public static func split(_ text: String) -> (body: String, questions: [String]) {
        let lines = trimmed(text[...]).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let marker = lines.lastIndex(where: { $0 == Mechanic.suggestedQuestionsMarker }) else {
            return (text, [])
        }
        let listed = lines[(marker + 1)...]
        guard (1...3).contains(listed.count), listed.allSatisfy({ $0.hasPrefix("- ") }) else { return (text, []) }
        let body = String(trimmed(text[..<lines[marker].startIndex]))
        return (body, listed.map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) })
    }

    /// `text` without the whitespace at its end.
    private static func trimmed(_ text: Substring) -> Substring {
        text.lastIndex(where: { !$0.isWhitespace }).map { text[...$0] } ?? text.prefix(0)
    }
}

/// The web pages an answer cites, for the numbered list under it.
public enum Sources {
    public struct Source: Equatable, Sendable {
        public var url: String
        public var title: String
    }

    /// The `web_search_result_location` citations of the `text` blocks of `content`, once for each URL, in the order
    /// they first appear and with the title of the first. A citation without a title is listed under its URL, and one
    /// without a URL is left out.
    public static func list(in content: [JSON]) -> [Source] {
        var sources: [Source] = []
        for block in content where block["type"]?.string == "text" {
            let citations = block["citations"]?.array ?? []
            for citation in citations where citation["type"]?.string == "web_search_result_location" {
                guard let url = citation["url"]?.string, !sources.contains(where: { $0.url == url }) else { continue }
                sources.append(Source(url: url, title: citation["title"]?.string ?? url))
            }
        }
        return sources
    }
}
