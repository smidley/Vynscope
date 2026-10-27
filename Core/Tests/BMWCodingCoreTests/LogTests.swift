import Foundation
import Testing
@testable import BMWCodingCore

@Test func logAppendsToFileAndText() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID()).txt")
    let log = Log()
    try log.attachFile(url)
    log.sent("ATZ"); log.received("ELM327 v1.4b"); log.note("connected")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines[0].hasSuffix(" → ATZ"))
    #expect(lines[1].hasSuffix(" ← ELM327 v1.4b"))
    #expect(lines[2].hasSuffix(" · connected"))
    #expect(log.asText() == lines.joined(separator: "\n") + "\n")
    #expect(log.entries.count == 3)
}

@Test func attachFileKeepsExistingContentAndWritesOnlyLaterEntries() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID()).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try "previous run\n".write(to: url, atomically: true, encoding: .utf8)
    let log = Log()
    log.note("before attach")
    try log.attachFile(url)
    log.sent("ATZ")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.wholeMatch(of: /previous run\n\d{2}:\d{2}:\d{2}\.\d{3} → ATZ\n/) != nil)
    #expect(log.entries.count == 2)
}

@Test func attachFileThrowsWhenTheFileCannotBeOpenedAndTheLogStillRecords() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("no-such-folder-\(UUID())").appendingPathComponent("log.txt")
    let log = Log()
    #expect(throws: (any Error).self) { try log.attachFile(url) }
    log.sent("ATZ")
    #expect(log.entries.count == 1)
}

@Test func lineStartsWithTheEntryTimeAsHHmmssSSS() throws {
    let log = Log()
    log.sent("ATZ")
    let time = try #require(log.entries.first).time, calendar = Calendar.current
    let hms = String(format: "%02d:%02d:%02d.", calendar.component(.hour, from: time),
        calendar.component(.minute, from: time), calendar.component(.second, from: time))
    #expect(log.asText().hasPrefix(hms))
    #expect(log.asText().wholeMatch(of: /\d{2}:\d{2}:\d{2}\.\d{3} → ATZ\n/) != nil)
}
