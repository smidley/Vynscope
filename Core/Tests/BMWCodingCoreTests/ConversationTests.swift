import Foundation
import Testing
@testable import BMWCodingCore

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
}

@Test func conversationRoundTripsThroughTheStore() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic) == nil)
    var conversation = Conversation(vin: "WBY73AW04RFFAKE19", started: Date(timeIntervalSince1970: 1_793_000_000), model: "claude-opus-5-5", carContext: "{}")
    conversation.messages = [.object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("hi")])])])]
    conversation.turns = [.init(messageIndex: 0, usage: Usage(inputTokens: 10, outputTokens: 5, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, webSearchRequests: 1, webFetchRequests: 0), rounds: 1, refused: false, truncated: false, stoppedAtRoundCap: false, stopped: false, model: "claude-opus-5-5")]
    try store.save(conversation)
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Conversations/WBY73AW04RFFAKE19-anthropic.json").path))
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic) == conversation)
    #expect(conversation.totalUsage.webSearchRequests == 1)
    try store.deleteAll(provider: .anthropic)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic) == nil)
    try store.deleteAll(provider: .anthropic)
}
@Test func deleteAllRemovesOneProvidersConversationsOfEveryCar() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    try store.deleteAll(provider: .openai)  // no folder yet: not an error
    let started = Date(timeIntervalSince1970: 1_793_000_000), cars = ["WBY73AW04RFFAKE19", "WBA00000000FAKE01"]
    func save(_ vin: String, _ provider: Provider) throws {
        try store.save(Conversation(vin: vin, started: started, model: "m", carContext: "{}", provider: provider))
    }
    for vin in cars {
        try save(vin, .anthropic)
        try save(vin, .openai)
    }
    // A third car's conversation from before there were providers, which is Anthropic's.
    try save("WBA00000000FAKE02", .anthropic)
    let conversations = folder.appending(path: "Conversations")
    try FileManager.default.moveItem(
        at: conversations.appending(path: "WBA00000000FAKE02-anthropic.json"),
        to: conversations.appending(path: "WBA00000000FAKE02.json"))
    #expect(store.load(vin: "WBA00000000FAKE02", provider: .anthropic) != nil)

    try store.deleteAll(provider: .openai)
    #expect(cars.allSatisfy { store.load(vin: $0, provider: .openai) == nil })
    #expect(cars.allSatisfy { store.load(vin: $0, provider: .anthropic) != nil })
    #expect(store.load(vin: "WBA00000000FAKE02", provider: .anthropic) != nil)

    try save(cars[0], .openai)
    try store.deleteAll(provider: .anthropic)
    #expect(cars.allSatisfy { store.load(vin: $0, provider: .anthropic) == nil })
    #expect(store.load(vin: "WBA00000000FAKE02", provider: .anthropic) == nil)
    #expect(store.load(vin: cars[0], provider: .openai) != nil)
}
@Test func deleteRemovesOnlyThatCarsConversation() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    try store.delete(vin: "WBY73AW04RFFAKE19", provider: .anthropic)  // no folder yet: not an error
    let started = Date(timeIntervalSince1970: 1_793_000_000)
    let mine = Conversation(vin: "WBY73AW04RFFAKE19", started: started, model: "claude-opus-5-5", carContext: "{}")
    let other = Conversation(vin: "WBA00000000FAKE01", started: started, model: "claude-opus-5-5", carContext: "{}")
    try store.save(mine)
    try store.save(other)
    try store.delete(vin: "WBY73AW04RFFAKE19", provider: .anthropic)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic) == nil)
    #expect(store.load(vin: "WBA00000000FAKE01", provider: .anthropic) == other)
    try store.delete(vin: "WBY73AW04RFFAKE19", provider: .anthropic)  // already gone: not an error
}
@Test func chipsComeOffTheEnd() {
    let text = "Two faults.\n\nSuggested questions:\n- Is the camera related?\n- What would a dealer charge?\n"
    let (body, questions) = Chips.split(text)
    #expect(body == "Two faults." && questions == ["Is the camera related?", "What would a dealer charge?"])
    #expect(Chips.split("No chips here.").questions.isEmpty)
    #expect(Chips.split("Suggested questions:\n- one\n- two\n- three\n- four").questions.isEmpty)
    #expect(Chips.split("Suggested questions:\nnot a list").body == "Suggested questions:\nnot a list")
}
@Test func sourcesAreUniqueInOrder() {
    func cite(_ url: String) -> JSON { .object(["type": .string("web_search_result_location"), "url": .string(url), "title": .string("T " + url), "encrypted_index": .string("x"), "cited_text": .string("c")]) }
    let content: [JSON] = [
        .object(["type": .string("text"), "text": .string("a"), "citations": .array([cite("https://a"), cite("https://b")])]),
        .object(["type": .string("server_tool_use"), "id": .string("s"), "name": .string("web_search"), "input": .object([:])]),
        .object(["type": .string("text"), "text": .string("b"), "citations": .array([cite("https://a"), cite("https://c")])])]
    #expect(Sources.list(in: content) == [Sources.Source(url: "https://a", title: "T https://a"), Sources.Source(url: "https://b", title: "T https://b"), Sources.Source(url: "https://c", title: "T https://c")])
}

// What the brief's values above do not isolate.

@Test func totalUsageAddsUpEveryTurn() {
    func turn(_ usage: Usage) -> TurnRecord {
        .init(messageIndex: 0, usage: usage, rounds: 1, refused: false, truncated: false, stoppedAtRoundCap: false, stopped: false, model: "claude-opus-5-5")
    }
    var conversation = Conversation(vin: "WBY73AW04RFFAKE19", started: Date(timeIntervalSince1970: 1_793_000_000), model: "claude-opus-5-5", carContext: "{}")
    #expect(conversation.messages.isEmpty && conversation.turns.isEmpty && conversation.totalUsage == .zero)
    conversation.turns = [
        turn(Usage(inputTokens: 10, outputTokens: 5, cacheCreationInputTokens: 1, cacheReadInputTokens: 2, webSearchRequests: 1, webFetchRequests: 0)),
        turn(Usage(inputTokens: 20, outputTokens: 7, cacheCreationInputTokens: 3, cacheReadInputTokens: 4, webSearchRequests: 2, webFetchRequests: 1))]
    #expect(conversation.totalUsage == Usage(inputTokens: 30, outputTokens: 12, cacheCreationInputTokens: 4, cacheReadInputTokens: 6, webSearchRequests: 3, webFetchRequests: 1))
}
@Test func aFileThatCannotBeDecodedIsNoConversationAndTheNextSaveReplacesIt() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    let file = folder.appending(path: "Conversations/WBY73AW04RFFAKE19.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"vin": "WBY73AW04RFFAKE19"}"#.utf8).write(to: file)  // valid JSON, but not a conversation
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic) == nil)
    let conversation = Conversation(vin: "WBY73AW04RFFAKE19", started: Date(timeIntervalSince1970: 1_793_000_000), model: "claude-opus-5-5", carContext: "{}")
    try store.save(conversation)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic) == conversation)
}
@Test func theFileIsPrettyPrintedWithSortedKeysAndIsoDates() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try ConversationStore(directory: folder).save(Conversation(vin: "WBY73AW04RFFAKE19", started: Date(timeIntervalSince1970: 1_793_000_000), model: "claude-opus-5-5", carContext: "{}"))
    let text = try String(contentsOf: folder.appending(path: "Conversations/WBY73AW04RFFAKE19-anthropic.json"), encoding: .utf8)
    #expect(text.hasPrefix("{\n  \"carContext\" : "))  // indented, and `carContext` first, which only sorting does
    #expect(text.contains("\"started\" : \"2026-10-26T07:33:20Z\""))
}
@Test func chipsTakeOneToThreeQuestionsAtTheVeryEnd() {
    let (body, questions) = Chips.split("Done.\nSuggested questions:\n- one\n- two \n-  three\n\n")
    #expect(body == "Done." && questions == ["one", "two", "three"])
    #expect(Chips.split("Suggested questions:\n- only").questions == ["only"])
    #expect(Chips.split("Suggested questions:\n- only").body == "")
    // Not the end of the text, not a list, not exactly the line, or no question at all: the text is the body as it is.
    for text in ["Suggested questions:\n- one\nThanks.", "Suggested questions:\n- one\n\n- two", "Suggested questions: \n- one", "Suggested questions:\n"] {
        let (body, questions) = Chips.split(text)
        #expect(body == text && questions.isEmpty)
    }
}
@Test func sourcesAreOnlyTheWebCitationsOfTheText() {
    func cite(_ type: String, _ url: String?, _ title: String?) -> JSON {
        .object(["type": .string(type), "url": url.map(JSON.string) ?? .null, "title": title.map(JSON.string) ?? .null])
    }
    let content: [JSON] = [
        .object(["type": .string("text"), "text": .string("a"), "citations": .array([
            cite("web_search_result_location", "https://a", "First"), cite("char_location", "https://skip", "Skip"),
            cite("web_search_result_location", "https://a", "Second"), cite("web_search_result_location", "https://b", nil),
            cite("web_search_result_location", nil, "No URL")])]),
        .object(["type": .string("web_search_tool_result"), "citations": .array([cite("web_search_result_location", "https://no", "No")])]),
        .object(["type": .string("text"), "text": .string("none")])]
    #expect(Sources.list(in: content) == [Sources.Source(url: "https://a", title: "First"), Sources.Source(url: "https://b", title: "https://b")])
    #expect(Sources.list(in: []).isEmpty)
}
@Test func consecutiveTextBlocksAreOneRun() {
    func text(_ value: String) -> JSON { .object(["type": .string("text"), "text": .string(value)]) }
    let cited: JSON = .object(["type": .string("text"), "text": .string("the nozzle is blocked"), "citations": .array([
        .object(["type": .string("web_search_result_location"), "url": .string("https://a"), "title": .string("A"), "cited_text": .string("nozzle")])])])
    #expect(Transcript.textRuns(in: [text("Based on the results, "), cited, text(".")])
        == [Transcript.TextRun(text: "Based on the results, the nozzle is blocked.", lastBlockIndex: 2)])
    let toolUse: JSON = .object(["type": .string("tool_use"), "id": .string("t"), "name": .string("get_vehicle"), "input": .object([:])])
    #expect(Transcript.textRuns(in: [text("Let me look."), toolUse, text("Done.")])
        == [Transcript.TextRun(text: "Let me look.", lastBlockIndex: 0), Transcript.TextRun(text: "Done.", lastBlockIndex: 2)])
    #expect(Transcript.textRuns(in: []).isEmpty)
}
@Test func aTurnSavedBeforeErrorAndActivityStillLoads() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "Conversations/WBY73AW04RFFAKE19.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
        {"carContext": "{}", "messages": [], "model": "claude-opus-5-5", "started": "2026-10-26T07:33:20Z",
         "turns": [{"messageIndex": 0, "model": "claude-opus-5-5", "refused": false, "rounds": 0, "stopped": true,
                    "stoppedAtRoundCap": false, "truncated": false,
                    "usage": {"cacheCreationInputTokens": 0, "cacheReadInputTokens": 0, "inputTokens": 10,
                              "outputTokens": 5, "webFetchRequests": 0, "webSearchRequests": 0}}],
         "vin": "WBY73AW04RFFAKE19"}
        """.utf8).write(to: file)
    let store = ConversationStore(directory: folder)
    var conversation = try #require(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic))
    let turn = try #require(conversation.turns.first)
    #expect(turn.error == nil && turn.activity == [] && turn.stopped && turn.usage.inputTokens == 10)
    conversation.turns[0].error = "API error (authentication_error): invalid x-api-key"
    conversation.turns[0].activity = ["Read 1 fault code from BDC_BODY3", "Searched the web: \"801E2B\""]
    try store.save(conversation)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic) == conversation)
}
@Test func fetchedPagesAreAmongTheSources() {
    func fetched(_ url: String, title: String?) -> JSON {
        .object(["type": .string("web_fetch_tool_result"), "tool_use_id": .string("f"), "content": .object([
            "type": .string("web_fetch_result"), "url": .string(url),
            "content": .object(["type": .string("document"), "title": title.map(JSON.string) ?? .null])])])
    }
    func cited(_ url: String) -> JSON {
        .object(["type": .string("text"), "text": .string("a"), "citations": .array([
            .object(["type": .string("web_search_result_location"), "url": .string(url), "title": .string("Forum")])])])
    }
    #expect(Sources.list(in: [fetched("https://fetched", title: "Service note"), cited("https://searched")])
        == [Sources.Source(url: "https://fetched", title: "Service note"), Sources.Source(url: "https://searched", title: "Forum")])
    // A page without a title is listed under its URL, and once, however often it is fetched or cited.
    #expect(Sources.list(in: [fetched("https://fetched", title: nil), cited("https://fetched")])
        == [Sources.Source(url: "https://fetched", title: "https://fetched")])
}

// Conversations per provider.

@Test func conversationsAreStoredPerProvider() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    let claude = Conversation(vin: "WBY73AW04RFFAKE19", started: .now, model: "claude-opus-5-5", carContext: "{}")
    var gpt = Conversation(vin: "WBY73AW04RFFAKE19", started: .now, model: "gpt-6.1-sol", carContext: "{}", provider: .openai)
    gpt.messages = [.object(["type": .string("message"), "role": .string("user"), "content": .string("hi")])]
    try store.save(claude)
    try store.save(gpt)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic)?.provider == .anthropic)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .openai)?.messages == gpt.messages)
    try store.delete(vin: "WBY73AW04RFFAKE19", provider: .openai)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .openai) == nil)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic) != nil)
}

@Test func aStageOneConversationFileLoadsAsAnthropics() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    let conversations = folder.appendingPathComponent("Conversations")
    try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
    let old = """
        {"carContext":"{}","messages":[],"model":"claude-opus-5-5","started":"2026-10-27T10:00:00Z",\
        "turns":[{"messageIndex":0,"model":"claude-opus-5-5","refused":false,"rounds":1,"stopped":false,\
        "stoppedAtRoundCap":false,"truncated":false,"usage":{"cacheCreationInputTokens":0,"cacheReadInputTokens":0,\
        "inputTokens":1,"outputTokens":1,"webFetchRequests":0,"webSearchRequests":0}}],"vin":"WBY73AW04RFFAKE19"}
        """
    try Data(old.utf8).write(to: conversations.appendingPathComponent("WBY73AW04RFFAKE19.json"))
    let loaded = try #require(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic))
    #expect(loaded.provider == .anthropic && loaded.turns.first?.provider == .anthropic)
    try store.save(loaded)  // moves to the per-provider file
    #expect(!FileManager.default.fileExists(atPath: conversations.appendingPathComponent("WBY73AW04RFFAKE19.json").path))
    #expect(FileManager.default.fileExists(atPath: conversations.appendingPathComponent("WBY73AW04RFFAKE19-anthropic.json").path))
}

// What the brief's tests above do not isolate: the turn's own new fields, which its custom decoder reads.

@Test func aTurnKeepsItsProviderAndWhetherWebSearchWasDropped() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    var gpt = Conversation(vin: "WBY73AW04RFFAKE19", started: Date(timeIntervalSince1970: 1_793_000_000), model: "gpt-6.1-sol", carContext: "{}", provider: .openai)
    gpt.turns = [.init(messageIndex: 0, usage: .zero, rounds: 1, refused: false, truncated: false, stoppedAtRoundCap: false, stopped: false, model: "gpt-6.1-sol", provider: .openai, webSearchDropped: true)]
    try store.save(gpt)
    let loaded = try #require(store.load(vin: "WBY73AW04RFFAKE19", provider: .openai))
    #expect(loaded == gpt)
    #expect(loaded.turns.first?.provider == .openai && loaded.turns.first?.webSearchDropped == true)
}

// The conversation's messages as the chat shows them.

@Test func anthropicMessagesBecomeTranscriptItems() {
    let messages: [JSON] = [
        Mechanic.ownerMessage("Summarize", provider: .anthropic),
        .object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("server_tool_use"), "id": .string("s1"), "name": .string("web_search"), "input": .object(["query": .string("B1F3E")])]),
            .object(["type": .string("tool_use"), "id": .string("t1"), "name": .string("read_faults"), "input": .object(["module": .string("40")])]),
        ])]),
        .object(["role": .string("user"), "content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("t1"), "content": .string("none"), "is_error": .bool(false)])])]),
        .object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("text"), "text": .string("Based on ")]),
            .object(["type": .string("text"), "text": .string("the results"), "citations": .array([.object(["type": .string("web_search_result_location"), "url": .string("https://a.example/p"), "title": .string("Page")])])]),
        ])]),
    ]
    let items = Transcript.items(in: messages, provider: .anthropic)
    #expect(items.map(\.kind) == [
        .owner("Summarize"), .webSearch(query: "B1F3E"),
        .toolCall(ToolCall(id: "t1", name: "read_faults", input: .object(["module": .string("40")])), result: ToolResult("none")),
        .mechanic("Based on the results"), .sources([Sources.Source(url: "https://a.example/p", title: "Page")]),
    ])
    #expect(items.map(\.messageIndex) == [0, 1, 1, 3, 3] && items[3].place == 1)
}

@Test func openAIItemsBecomeTranscriptItems() throws {
    let call = try JSON.parse(Data(functionCallItem(0, callId: "call_1", name: "read_faults", arguments: #"{"module":"40"}"#).json.utf8))
    let answer = try JSON.parse(Data(textItem(0, "Nothing stored.", citations: [("https://a.example/p", "Page"), ("https://a.example/p", "Page again")]).json.utf8))
    let messages: [JSON] = [
        Mechanic.ownerMessage("Summarize", provider: .openai),
        try JSON.parse(Data(reasoningItem(0).json.utf8)),
        try JSON.parse(Data(webSearchItem(0, query: "B1F3E").json.utf8)),
        .object(["id": .string("ws_2"), "type": .string("web_search_call"), "status": .string("completed"), "action": .object(["type": .string("open_page"), "url": .string("https://a.example/p")])]),
        call,
        .object(["type": .string("function_call_output"), "call_id": .string("call_1"), "namespace": .string("car"), "name": .string("read_faults"), "output": .string("Error: module 40 did not answer")]),
        answer,
    ]
    let items = Transcript.items(in: messages, provider: .openai)
    #expect(items.map(\.kind) == [
        .owner("Summarize"), .webSearch(query: "B1F3E"), .webFetch(url: "https://a.example/p"),
        .toolCall(ToolCall(id: "call_1", name: "read_faults", input: .object(["module": .string("40")])), result: ToolResult("module 40 did not answer", isError: true)),
        .mechanic("Nothing stored."), .sources([Sources.Source(url: "https://a.example/p", title: "Page")]),
    ])
    #expect(items.map(\.messageIndex) == [0, 2, 3, 4, 6, 6])
}

// What the brief's tests above do not isolate.

@Test func anAnthropicCallIsAnsweredByItsOwnIdAndTheBlocksThatShowNothingGiveNone() {
    let messages: [JSON] = [
        .object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("thinking"), "thinking": .string("hm"), "signature": .string("sig")]),
            .object(["type": .string("server_tool_use"), "id": .string("s1"), "name": .string("web_fetch"), "input": .object(["url": .string("https://a.example/p")])]),
            .object(["type": .string("web_fetch_tool_result"), "tool_use_id": .string("s1"), "content": .object(["type": .string("web_fetch_result"), "url": .string("https://a.example/p")])]),
            .object(["type": .string("server_tool_use"), "id": .string("s2"), "name": .string("code_execution"), "input": .object([:])]),
            .object(["type": .string("fallback")]),
            .object(["type": .string("tool_use"), "id": .string("t1"), "name": .string("get_vehicle"), "input": .object([:])]),
            .object(["type": .string("tool_use"), "id": .string("t2"), "name": .string("read_obd"), "input": .object(["pid": .string("42")])]),
        ])]),
        .object(["role": .string("user"), "content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("t2"), "content": .string("boom"), "is_error": .bool(true)])])]),
    ]
    let items = Transcript.items(in: messages, provider: .anthropic)
    #expect(items.map(\.kind) == [
        .webFetch(url: "https://a.example/p"), .fallback,
        .toolCall(ToolCall(id: "t1", name: "get_vehicle", input: .object([:])), result: nil),
        .toolCall(ToolCall(id: "t2", name: "read_obd", input: .object(["pid": .string("42")])), result: ToolResult("boom", isError: true)),
    ])
    #expect(items.map(\.place) == [1, 4, 5, 6])
}

@Test func theSourcesFollowTheLastTextAndEmptyTextShowsNothing() {
    func text(_ value: String, citing url: String? = nil) -> JSON {
        var block: [String: JSON] = ["type": .string("text"), "text": .string(value)]
        if let url { block["citations"] = .array([.object(["type": .string("web_search_result_location"), "url": .string(url), "title": .string("Page")])]) }
        return .object(block)
    }
    let call = ToolCall(id: "t", name: "get_vehicle", input: .object([:]))
    let messages: [JSON] = [
        .object(["role": .string("assistant"), "content": .array([
            text("Looking.", citing: "https://a.example/p"),
            .object(["type": .string("tool_use"), "id": .string("t"), "name": .string("get_vehicle"), "input": .object([:])]),
            text("Done."), text(""),
        ])]),
        .object(["role": .string("assistant"), "content": .array([text("No sources here.")])]),
        .object(["role": .string("assistant"), "content": .array([text("")])]),
    ]
    let items = Transcript.items(in: messages, provider: .anthropic)
    // The cited text is not the last, so its page is listed after the message's last text, which ends at block 3.
    #expect(items.map(\.kind) == [
        .mechanic("Looking."), .toolCall(call, result: nil), .mechanic("Done."),
        .sources([Sources.Source(url: "https://a.example/p", title: "Page")]), .mechanic("No sources here."),
    ])
    #expect(items.map(\.messageIndex) == [0, 0, 0, 0, 1] && items.map(\.place) == [0, 1, 3, 3, 0])
}

@Test func openAITextIsJoinedAndARefusalStillShows() {
    let owner = JSON.object(["role": .string("user"), "content": .string("hello")])
    let refusal = JSON.object(["type": .string("message"), "role": .string("assistant"), "content": .array([.object(["type": .string("refusal"), "refusal": .string("I can't help with that.")])])])
    let parts = JSON.object(["type": .string("message"), "role": .string("assistant"), "content": .array([
        .object(["type": .string("output_text"), "text": .string("Part one. "), "annotations": .array([.object(["type": .string("file_citation"), "file_id": .string("f"), "url": .string("https://not.a.url.citation")])])]),
        .object(["type": .string("output_text"), "text": .string("Part two."), "annotations": .array([])]),
    ])])
    let items = Transcript.items(in: [owner, refusal, parts], provider: .openai)
    // Only a `url_citation` lists a page, so there are no sources here.
    #expect(items.map(\.kind) == [.owner("hello"), .mechanic("I can't help with that."), .mechanic("Part one. Part two.")])
    #expect(items.map(\.messageIndex) == [0, 1, 2] && items.allSatisfy { $0.place == 0 })
}

@Test func openAICallsAreAnsweredByTheirOwnLaterOutput() throws {
    func call(_ id: String, _ arguments: String) throws -> JSON {
        try JSON.parse(Data(functionCallItem(0, callId: id, name: "read_obd", arguments: arguments).json.utf8))
    }
    func output(_ id: String, _ text: String) -> JSON {
        .object(["type": .string("function_call_output"), "call_id": .string(id), "output": .string(text)])
    }
    let messages: [JSON] = [
        output("c2", "too early"), try call("c1", "not json"), try call("c2", #"{"pid":"42"}"#), try call("c3", "{}"),
        output("c3", "Error: no answer"), output("c2", #"{"ok":true}"#),
        .object(["id": .string("ws_1"), "type": .string("web_search_call"), "status": .string("completed"), "action": .object(["type": .string("find_in_page"), "url": .string("https://a.example/p"), "pattern": .string("x")])]),
    ]
    let items = Transcript.items(in: messages, provider: .openai)
    #expect(items.map(\.kind) == [
        .toolCall(ToolCall(id: "c1", name: "read_obd", input: .object([:])), result: nil),
        .toolCall(ToolCall(id: "c2", name: "read_obd", input: .object(["pid": .string("42")])), result: ToolResult(#"{"ok":true}"#)),
        .toolCall(ToolCall(id: "c3", name: "read_obd", input: .object([:])), result: ToolResult("no answer", isError: true)),
    ])
    #expect(items.map(\.messageIndex) == [1, 2, 3])
}

// The seam end to end: what each client stores for a turn reads back as the same rows.

@Test(arguments: Provider.allCases)
func aTurnRunsOnEitherClientThroughTheSeamAndReadsBackAsItems(provider: Provider) async throws {
    let client: any ModelClient
    switch provider {
    case .anthropic:
        client = ClaudeClient(transport: FakeTransport([
            (200, [:], toolUseStream(id: "t1", name: "read_faults", input: #"{"module":"40"}"#)),
            (200, [:], textStream("Nothing stored.")),
        ]), apiKey: "k", log: Log())
    case .openai:
        client = OpenAIClient(transport: FakeTransport([
            (200, [:], responsesStream([functionCallItem(0, callId: "t1", name: "read_faults", arguments: #"{"module":"40"}"#)])),
            (200, [:], responsesStream([textItem(0, "Nothing stored.")])),
        ]), accessToken: "t", log: Log())
    }
    var messages = [Mechanic.ownerMessage("Look", provider: provider)]
    let turn = try await client.run(
        messages: &messages, system: Mechanic.systemPrompt(carContext: "{}", web: provider == .anthropic ? .searchAndFetch : .search),
        tools: Mechanic.tools, model: "m", effort: "low",
        runTool: { _ in ToolResult("module 40 did not answer", isError: true) }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(turn.rounds == 1)
    #expect(Transcript.items(in: messages, provider: provider).map(\.kind) == [
        .owner("Look"),
        .toolCall(ToolCall(id: "t1", name: "read_faults", input: .object(["module": .string("40")])), result: ToolResult("module 40 did not answer", isError: true)),
        .mechanic("Nothing stored."),
    ])
}
