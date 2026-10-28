import Foundation
import Testing
@testable import BMWCodingCore

@Test func conversationRoundTripsThroughTheStore() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    #expect(store.load(vin: "WBY73AW04RFFAKE19") == nil)
    var conversation = Conversation(vin: "WBY73AW04RFFAKE19", started: Date(timeIntervalSince1970: 1_793_000_000), model: "claude-opus-5-5", carContext: "{}")
    conversation.messages = [.object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("hi")])])])]
    conversation.turns = [.init(messageIndex: 0, usage: Usage(inputTokens: 10, outputTokens: 5, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, webSearchRequests: 1, webFetchRequests: 0), rounds: 1, refused: false, truncated: false, stoppedAtRoundCap: false, stopped: false, model: "claude-opus-5-5")]
    try store.save(conversation)
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Conversations/WBY73AW04RFFAKE19.json").path))
    #expect(store.load(vin: "WBY73AW04RFFAKE19") == conversation)
    #expect(conversation.totalUsage.webSearchRequests == 1)
    try store.deleteAll()
    #expect(store.load(vin: "WBY73AW04RFFAKE19") == nil)
    try store.deleteAll()
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
    #expect(store.load(vin: "WBY73AW04RFFAKE19") == nil)
    let conversation = Conversation(vin: "WBY73AW04RFFAKE19", started: Date(timeIntervalSince1970: 1_793_000_000), model: "claude-opus-5-5", carContext: "{}")
    try store.save(conversation)
    #expect(store.load(vin: "WBY73AW04RFFAKE19") == conversation)
}
@Test func theFileIsPrettyPrintedWithSortedKeysAndIsoDates() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try ConversationStore(directory: folder).save(Conversation(vin: "WBY73AW04RFFAKE19", started: Date(timeIntervalSince1970: 1_793_000_000), model: "claude-opus-5-5", carContext: "{}"))
    let text = try String(contentsOf: folder.appending(path: "Conversations/WBY73AW04RFFAKE19.json"), encoding: .utf8)
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
