import Foundation

/// One chat with the mechanic about one car, with one provider: the messages as that provider's API takes them, so that
/// the next turn carries on from them, and how each turn went.
public struct Conversation: Codable, Equatable {
    public var vin: String
    public var started: Date
    public var model: String
    /// The provider whose API `messages` are in and that answered the turns.
    public var provider: Provider
    /// The health check's findings as JSON text, which the system prompt carries.
    public var carContext: String
    public var messages: [JSON]
    public var turns: [TurnRecord]

    /// `messages` and `turns` are empty unless given, as in a new conversation, and `provider` is Anthropic.
    public init(
        vin: String, started: Date, model: String, carContext: String, messages: [JSON] = [], turns: [TurnRecord] = [],
        provider: Provider = .anthropic
    ) {
        self.vin = vin
        self.started = started
        self.model = model
        self.provider = provider
        self.carContext = carContext
        self.messages = messages
        self.turns = turns
    }

    /// Reads a conversation as `save` wrote it; one written before conversations were kept per provider has no
    /// `provider`, and is Anthropic's.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vin = try container.decode(String.self, forKey: .vin)
        started = try container.decode(Date.self, forKey: .started)
        model = try container.decode(String.self, forKey: .model)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? .anthropic
        carContext = try container.decode(String.self, forKey: .carContext)
        messages = try container.decode([JSON].self, forKey: .messages)
        turns = try container.decode([TurnRecord].self, forKey: .turns)
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
    /// The provider that ran the turn.
    public var provider: Provider
    /// What went wrong, as the chat said it, when the turn failed; `nil` otherwise.
    public var error: String?
    /// The turn's reads and web lookups, a line each, as the chat showed them while it ran.
    public var activity: [String]
    /// The turn ran without web search, because the model would not take it.
    public var webSearchDropped: Bool

    public init(
        messageIndex: Int, usage: Usage, rounds: Int, refused: Bool, truncated: Bool, stoppedAtRoundCap: Bool,
        stopped: Bool, model: String, error: String? = nil, activity: [String] = [], provider: Provider = .anthropic,
        webSearchDropped: Bool = false
    ) {
        self.messageIndex = messageIndex
        self.usage = usage
        self.rounds = rounds
        self.refused = refused
        self.truncated = truncated
        self.stoppedAtRoundCap = stoppedAtRoundCap
        self.stopped = stopped
        self.model = model
        self.provider = provider
        self.error = error
        self.activity = activity
        self.webSearchDropped = webSearchDropped
    }

    /// Reads a record as `save` wrote it; one written before turns kept their `error` and `activity` has neither, and
    /// one written before conversations were kept per provider has no `provider`, which is Anthropic, and no
    /// `webSearchDropped`, which is `false`.
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
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? .anthropic
        error = try container.decodeIfPresent(String.self, forKey: .error)
        activity = try container.decodeIfPresent([String].self, forKey: .activity) ?? []
        webSearchDropped = try container.decodeIfPresent(Bool.self, forKey: .webSearchDropped) ?? false
    }
}

/// The folder the conversations live in, one JSON file per car and provider: `Conversations/<vin>-<provider>.json`. A
/// VIN is letters and digits (`VIN.isValid`), so it is a file name as it is. Dates are written as ISO 8601 text, in
/// whole seconds. Before there were providers a car's file was `Conversations/<vin>.json`; that one is Anthropic's,
/// and is read until Anthropic's conversation is saved.
public struct ConversationStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The conversation of the car with this VIN with `provider`, or `nil` when there is no file or it cannot be
    /// decoded, in which case the next `save` replaces it. Anthropic's is read from the file of before there were
    /// providers when it has none of its own.
    public func load(vin: String, provider: Provider) -> Conversation? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var url = file(vin: vin, provider: provider)
        if provider == .anthropic, !FileManager.default.fileExists(atPath: url.path) { url = legacyFile(vin: vin) }
        return try? decoder.decode(Conversation.self, from: Data(contentsOf: url))
    }

    /// Writes the conversation to the file of its car and provider as pretty-printed JSON with sorted keys, creating
    /// the folders on the way. The file is replaced as a whole, so a crash half-way leaves the old one. Anthropic's
    /// conversation also removes the car's file of before there were providers, which it replaces; a removal that
    /// fails is ignored.
    public func save(_ conversation: Conversation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(conversation).write(
            to: file(vin: conversation.vin, provider: conversation.provider), options: .atomic)
        if conversation.provider == .anthropic {
            try? FileManager.default.removeItem(at: legacyFile(vin: conversation.vin))
        }
    }

    /// Removes the conversation of the car with this VIN with `provider`: its file, and for Anthropic's the file of
    /// before there were providers too, first, so that a removal that fails cannot bring the older one back. Their
    /// being missing is not an error.
    public func delete(vin: String, provider: Provider) throws {
        var urls = [file(vin: vin, provider: provider)]
        if provider == .anthropic { urls.insert(legacyFile(vin: vin), at: 0) }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Removes every car's conversation with `provider`: the files `<vin>-<provider>.json`, and for Anthropic's the
    /// files of before there were providers, `<vin>.json`, first, as `delete` does. The other provider's files stay.
    /// The folder's being missing is not an error.
    public func deleteAll(provider: Provider) throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        // The folder lists its files in no fixed order: the names without a dash go first.
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted(by: { !$0.lastPathComponent.contains("-") && $1.lastPathComponent.contains("-") })
        where url.pathExtension == "json" {
            let name = url.deletingPathExtension().lastPathComponent
            // A VIN has no dash, so a name without one is a file of before there were providers.
            if name.hasSuffix("-\(provider.rawValue)") || (provider == .anthropic && !name.contains("-")) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private var folder: URL { directory.appendingPathComponent("Conversations") }

    private func file(vin: String, provider: Provider) -> URL {
        folder.appendingPathComponent("\(vin)-\(provider.rawValue).json")
    }

    /// Where a car's conversation was kept before there were providers: Anthropic's.
    private func legacyFile(vin: String) -> URL { folder.appendingPathComponent("\(vin).json") }
}

/// The conversation's messages as the chat shows them.
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

    /// One thing the chat shows from a message of the conversation.
    public struct Item: Equatable, Sendable {
        /// The index in the conversation's messages the item comes from.
        public var messageIndex: Int
        /// The index of the block or part inside that message, for stable row ids. A text and the pages it cites can
        /// share one.
        public var place: Int
        public var kind: Kind
    }

    public enum Kind: Equatable, Sendable {
        case owner(String)
        /// One run of the mechanic's text.
        case mechanic(String)
        /// A tool the mechanic called, with its result when the conversation holds one.
        case toolCall(ToolCall, result: ToolResult?)
        case webSearch(query: String)
        case webFetch(url: String)
        case fallback
        /// The pages the message cites, after its last text.
        case sources([Sources.Source])
    }

    /// What the chat shows of `messages`, which are in `provider`'s own shape, in order: the owner's text, the
    /// mechanic's text a run at a time (a run with no text is left out), each tool call with its result, each web
    /// lookup, a fallback, and the pages an answer cites after its last text. Everything else, the mechanic's
    /// thinking and the web tools' own results among it, shows nothing.
    public static func items(in messages: [JSON], provider: Provider) -> [Item] {
        switch provider {
        case .anthropic: anthropicItems(in: messages)
        case .openai: openAIItems(in: messages)
        }
    }

    /// Messages API messages: an owner message gives an item for each of its text blocks, and an assistant message
    /// one for each block that shows, a text run at its last block.
    private static func anthropicItems(in messages: [JSON]) -> [Item] {
        var items: [Item] = []
        for (index, message) in messages.enumerated() {
            func add(_ place: Int, _ kind: Kind) { items.append(Item(messageIndex: index, place: place, kind: kind)) }
            let content = message["content"]?.array ?? []
            if message["role"]?.string == "assistant" {
                // The tool results answering this message's calls, in the message after it.
                let results = index + 1 < messages.count ? messages[index + 1]["content"]?.array ?? [] : []
                // Each run of text blocks, as a cited answer arrives split at its citations, by its last block.
                let runs = Dictionary(uniqueKeysWithValues: textRuns(in: content).map { ($0.lastBlockIndex, $0.text) })
                let lastText = content.lastIndex { $0["type"]?.string == "text" }
                for (place, block) in content.enumerated() {
                    switch block["type"]?.string {
                    case "text":
                        guard let text = runs[place] else { break }  // its run shows at the run's last block
                        if !text.isEmpty { add(place, .mechanic(text)) }
                        let sources = place == lastText ? Sources.list(in: content) : []
                        if !sources.isEmpty { add(place, .sources(sources)) }
                    case "tool_use":
                        let answer = results.first {
                            $0["type"]?.string == "tool_result" && $0["tool_use_id"] == block["id"]
                        }
                        let call = ToolCall(
                            id: block["id"]?.string ?? "", name: block["name"]?.string ?? "",
                            input: block["input"] ?? .object([:]))
                        let result = answer.map {
                            ToolResult($0["content"]?.string ?? "", isError: $0["is_error"]?.bool ?? false)
                        }
                        add(place, .toolCall(call, result: result))
                    case "server_tool_use":
                        switch block["name"]?.string {
                        case "web_search": add(place, .webSearch(query: block["input"]?["query"]?.string ?? ""))
                        case "web_fetch": add(place, .webFetch(url: block["input"]?["url"]?.string ?? ""))
                        default: break
                        }
                    case "fallback":
                        add(place, .fallback)
                    default:
                        break  // thinking, the web tools' results, and anything a later API version adds
                    }
                }
            } else if Mechanic.isOwnerMessage(message, provider: .anthropic) {
                for (place, block) in content.enumerated() where block["type"]?.string == "text" {
                    add(place, .owner(block["text"]?.string ?? ""))
                }
            }
        }
        return items
    }

    /// Responses input items, one message each: a user message gives its text, an assistant message its text and
    /// then the pages it cites, a function call itself with the output a later item gives it, a web search call its
    /// search or page. Their reasoning and function outputs, which the calls take, show nothing.
    private static func openAIItems(in messages: [JSON]) -> [Item] {
        var items: [Item] = []
        for (index, item) in messages.enumerated() {
            func add(_ place: Int, _ kind: Kind) { items.append(Item(messageIndex: index, place: place, kind: kind)) }
            switch item["type"]?.string {
            case "message", nil:
                let parts = item["content"]?.array ?? []
                if Mechanic.isOwnerMessage(item, provider: .openai) {
                    let inputs = parts.compactMap { $0["type"]?.string == "input_text" ? $0["text"]?.string : nil }
                    add(0, .owner(item["content"]?.string ?? inputs.joined()))
                } else if item["role"]?.string == "assistant" {
                    // What the model said, or refused to say.
                    let text = parts.compactMap { part -> String? in
                        switch part["type"]?.string {
                        case "output_text": part["text"]?.string
                        case "refusal": part["refusal"]?.string
                        default: nil
                        }
                    }.joined()
                    if !text.isEmpty { add(0, .mechanic(text)) }
                    let sources = Sources.list(inParts: parts)
                    if !sources.isEmpty { add(1, .sources(sources)) }
                }
            case "function_call":
                let id = item["call_id"]?.string ?? ""
                var input = JSON.object([:])
                if let parsed = try? JSON.parse(Data((item["arguments"]?.string ?? "").utf8)), parsed.object != nil {
                    input = parsed
                }
                let output = messages[(index + 1)...].first {
                    $0["type"]?.string == "function_call_output" && $0["call_id"]?.string == id
                }
                let result = output.map { output -> ToolResult in
                    let text = output["output"]?.string ?? ""
                    guard text.hasPrefix(OpenAIClient.errorPrefix) else { return ToolResult(text) }
                    return ToolResult(String(text.dropFirst(OpenAIClient.errorPrefix.count)), isError: true)
                }
                add(0, .toolCall(ToolCall(id: id, name: item["name"]?.string ?? "", input: input), result: result))
            case "web_search_call":
                let action = item["action"]
                switch action?["type"]?.string {
                case "search": add(0, .webSearch(query: action?["query"]?.string ?? ""))
                case "open_page": add(0, .webFetch(url: action?["url"]?.string ?? ""))
                default: break
                }
            default:
                break  // reasoning, function outputs, and anything a later API version adds
            }
        }
        return items
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
        for block in content {
            switch block["type"]?.string {
            case "text":
                let citations = block["citations"]?.array ?? []
                for citation in citations where citation["type"]?.string == "web_search_result_location" {
                    add(citation["url"]?.string, title: citation["title"]?.string, to: &sources)
                }
            case "web_fetch_tool_result":
                add(
                    block["content"]?["url"]?.string, title: block["content"]?["content"]?["title"]?.string,
                    to: &sources)
            default:
                break
            }
        }
        return sources
    }

    /// The `url_citation` annotations of the parts of a Responses message's `content`, listed as `list(in:)` lists
    /// those of the Messages API.
    static func list(inParts parts: [JSON]) -> [Source] {
        var sources: [Source] = []
        for part in parts {
            let annotations = part["annotations"]?.array ?? []
            for annotation in annotations where annotation["type"]?.string == "url_citation" {
                add(annotation["url"]?.string, title: annotation["title"]?.string, to: &sources)
            }
        }
        return sources
    }

    /// Adds the page at `url` to `sources` under `title`, or under its URL when it has none; a page already there,
    /// and one without a URL, are left out.
    private static func add(_ url: String?, title: String?, to sources: inout [Source]) {
        guard let url, !sources.contains(where: { $0.url == url }) else { return }
        sources.append(Source(url: url, title: title ?? url))
    }
}
