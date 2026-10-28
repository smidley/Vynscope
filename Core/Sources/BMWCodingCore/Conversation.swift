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

/// How one run of an owner message went, for the usage line under its answer. `usage`, `rounds`, `refused`,
/// `truncated` and `stoppedAtRoundCap` are those of the `Turn` it ran; a turn that was stopped or failed has the usage
/// of the requests it completed.
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
    /// What went wrong, as the chat said it, when the turn failed; `nil` otherwise.
    public var error: String?
    /// The turn's reads and web lookups, a line each, as the chat showed them while it ran.
    public var activity: [String]

    public init(
        messageIndex: Int, usage: Usage, rounds: Int, refused: Bool, truncated: Bool, stoppedAtRoundCap: Bool,
        stopped: Bool, model: String, error: String? = nil, activity: [String] = []
    ) {
        self.messageIndex = messageIndex
        self.usage = usage
        self.rounds = rounds
        self.refused = refused
        self.truncated = truncated
        self.stoppedAtRoundCap = stoppedAtRoundCap
        self.stopped = stopped
        self.model = model
        self.error = error
        self.activity = activity
    }

    /// Reads a record as `save` wrote it; one written before turns kept their `error` and `activity` has neither.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageIndex = try container.decode(Int.self, forKey: .messageIndex)
        usage = try container.decode(Usage.self, forKey: .usage)
        rounds = try container.decode(Int.self, forKey: .rounds)
        refused = try container.decode(Bool.self, forKey: .refused)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        stoppedAtRoundCap = try container.decode(Bool.self, forKey: .stoppedAtRoundCap)
        stopped = try container.decode(Bool.self, forKey: .stopped)
        model = try container.decode(String.self, forKey: .model)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        activity = try container.decodeIfPresent([String].self, forKey: .activity) ?? []
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

    /// Removes the conversation of the car with this VIN: its file. Its being missing is not an error.
    public func delete(vin: String) throws {
        let url = file(vin: vin)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes every conversation: the `Conversations` folder. Its being missing is not an error.
    public func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    private var folder: URL { directory.appendingPathComponent("Conversations") }

    private func file(vin: String) -> URL { folder.appendingPathComponent("\(vin).json") }
}

/// The text of an assistant message as the chat shows it.
public enum Transcript {
    /// Text blocks that follow one another, read as one text.
    public struct TextRun: Equatable, Sendable {
        /// Their texts joined as they are, with nothing between them.
        public var text: String
        /// The index of the run's last block in the content, where the chat shows the run among the other blocks.
        public var lastBlockIndex: Int
    }

    /// Every run of consecutive `text` blocks in `content`, each as long as it goes, in order. The API splits an
    /// answer that cites its sources into several text blocks, one break at each citation, and they read as one.
    public static func textRuns(in content: [JSON]) -> [TextRun] {
        var runs: [TextRun] = []
        for (index, block) in content.enumerated() where block["type"]?.string == "text" {
            let text = block["text"]?.string ?? ""
            if runs.last?.lastBlockIndex == index - 1 {
                runs[runs.count - 1].text += text
                runs[runs.count - 1].lastBlockIndex = index
            } else {
                runs.append(TextRun(text: text, lastBlockIndex: index))
            }
        }
        return runs
    }
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

/// The web pages an answer cites or fetched, for the numbered list under it.
public enum Sources {
    public struct Source: Equatable, Sendable {
        public var url: String
        public var title: String
    }

    /// The `web_search_result_location` citations of the `text` blocks of `content` and the pages of its
    /// `web_fetch_tool_result` blocks, once for each URL, in the order they first appear and with the title of the
    /// first. A page without a title is listed under its URL, and a citation or a fetch without a URL is left out.
    public static func list(in content: [JSON]) -> [Source] {
        var sources: [Source] = []
        func add(_ url: String?, title: String?) {
            guard let url, !sources.contains(where: { $0.url == url }) else { return }
            sources.append(Source(url: url, title: title ?? url))
        }
        for block in content {
            switch block["type"]?.string {
            case "text":
                let citations = block["citations"]?.array ?? []
                for citation in citations where citation["type"]?.string == "web_search_result_location" {
                    add(citation["url"]?.string, title: citation["title"]?.string)
                }
            case "web_fetch_tool_result":
                add(block["content"]?["url"]?.string, title: block["content"]?["content"]?["title"]?.string)
            default:
                break
            }
        }
        return sources
    }
}
