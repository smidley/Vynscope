import Foundation
import Testing
@testable import BMWCodingCore

@Test func sweepKeepsPositivesEntersSessionOnceAndSkipsNegatives() async throws {
    var session = false
    let link = FakeLink { cmd in
        if cmd == "56 02 10 03 00 00 00 00" { session = true; return ["656 F1 02 50 03 00 00 00 00"] }
        guard cmd.hasPrefix("56 03 22 30") else { return cmd.hasPrefix("AT") ? ["OK"] : ["656 F1 02 7E 00 00 00 00 00"] }
        let did = cmd.split(separator: " ")[3...4].joined()
        switch (did, session) {
        case ("3000", false): return ["656 F1 03 7F 22 7F 00 00 00"]
        case ("3000", true): return ["656 F1 04 62 30 00 AA 00 00"]
        case ("3002", _): return ["656 F1 05 62 30 02 01 02 00"]
        default: return ["656 F1 03 7F 22 31 00 00 00"] } }
    var ticks: [(Int, Int)] = []
    let data = try await Coding.read(diag: Diag(link: link, log: Log()), module: 0x56, dids: [0x3000, 0x3001, 0x3002]) { ticks.append(($0, $1)) }
    #expect(data == [0x3000: [0xAA], 0x3002: [0x01, 0x02]])
    #expect(ticks.last! == (3, 3))
    #expect(link.sent.filter { $0.hasPrefix("56 02 10 03") }.count == 1)
}
@Test func sweepStopsWhenModuleGoesSilent() async {
    let link = FakeLink { cmd in cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] }
    await #expect(throws: CodingError.moduleStoppedAnswering(after: 5)) {
        _ = try await Coding.read(diag: Diag(link: link, log: Log()), module: 0x56, dids: Array(0x3000...0x3010)) { _, _ in } }
}
@Test func rememberedSetsKeyedByCodingFileVersion() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sets-\(UUID()).json")
    var sets = RememberedSets.load(from: url)
    sets.remember([0x3000, 0x3002], address: 0x56, codingFiles: ["CAFD_000006C9_024_002_013"])
    try sets.save(to: url)
    let back = RememberedSets.load(from: url)
    #expect(back.dids(address: 0x56, codingFiles: ["CAFD_000006C9_024_002_013"]) == [0x3000, 0x3002])
    #expect(back.dids(address: 0x56, codingFiles: ["CAFD_000006C9_025_000_001"]) == nil)
    #expect(RememberedSets.key(address: 0x56, codingFiles: ["B", "A"]) == "56|A,B")
}

// Edge cases the scenarios above do not pin down.

// Module 0x56's answer to a read of any identifier: a negative response with `code`.
private func negative(_ code: UInt8) -> [String] { ["656 F1 03 7F 22 \(ISOTP.hexLine([code])) 00 00 00"] }
// What a read of identifier `did` from module 0x56 puts on the bus.
private func readRequest(_ did: UInt16) -> String {
    String(format: "56 03 22 %02X %02X 00 00 00", UInt8(did >> 8), UInt8(did & 0xFF))
}
// `count` identifiers from 0x3000 up.
private func ids(_ count: Int) -> [UInt16] { (0..<count).map { 0x3000 + UInt16($0) } }
// `Coding.read` from module 0x56 with the clock stopped, so no TesterPresent can come between two requests.
private func sweep(_ link: FakeLink, _ dids: [UInt16],
                   progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> [UInt16: [UInt8]] {
    let start = ContinuousClock.now
    return try await Coding.read(diag: Diag(link: link, log: Log()), module: 0x56, dids: dids, now: { start },
                                 progress: progress)
}
// A module 0x56 that answers the n-th identifier from 0x3000 as `pattern[n]` says: p a positive with the data
// AA, n a negative (0x31), s nothing. Adapter commands get OK.
private func answering(_ pattern: String) -> FakeLink {
    let kinds = Array(pattern)
    return FakeLink { cmd in
        let words = cmd.split(separator: " ")
        guard words.count == 8, words[2] == "22" else { return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] }
        let n = Int(words[4], radix: 16) ?? 0
        switch n < kinds.count ? kinds[n] : "s" {
        case "p": return ["656 F1 04 62 30 \(words[4]) AA 00 00"]
        case "n": return negative(0x31)
        default: return ["NO DATA"] } }
}

@Test func selectsTheModuleThenAsksEachIdentifierOnceInOrderAndNothingElse() async throws {
    let link = FakeLink { cmd in cmd.hasPrefix("AT") ? ["OK"] : negative(0x31) }
    var ticks: [[Int]] = []
    let data = try await sweep(link, [0x3000, 0x3001]) { ticks.append([$0, $1]) }
    #expect(data.isEmpty)
    #expect(link.sent == ["ATCRA 656", "ATFCSD 56 30 00 00", "56 03 22 30 00 00 00 00", "56 03 22 30 01 00 00 00"])
    #expect(ticks == [[1, 2], [2, 2]])  // an identifier the module refuses counts as done
}
@Test func theSessionIsEnteredOnceForEitherCodeAndTheIdentifierAskedAgainOnce() async throws {
    for code: UInt8 in [0x7F, 0x22] {  // not supported in the active session, conditions not correct
        // The module takes the session but still refuses every read, so nothing is kept.
        let link = FakeLink { cmd in
            switch cmd {
            case "56 02 10 03 00 00 00 00": return ["656 F1 02 50 03 00 00 00 00"]
            default: return cmd.hasPrefix("AT") ? ["OK"] : negative(code) } }
        var ticks: [[Int]] = []
        let data = try await sweep(link, [0x3000, 0x3001]) { ticks.append([$0, $1]) }
        #expect(data.isEmpty, "code \(code)")
        #expect(link.sent.filter { !$0.hasPrefix("AT") } == [
            readRequest(0x3000), "56 02 10 03 00 00 00 00", readRequest(0x3000), readRequest(0x3001),
        ], "code \(code)")
        #expect(ticks == [[1, 2], [2, 2]], "code \(code)")  // the identifier asked again counts once
    }
}
@Test func aRefusedSessionIsNotAskedForAgainAndNoIdentifierIsAskedTwice() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "56 02 10 03 00 00 00 00": return ["656 F1 03 7F 10 22 00 00 00"]  // conditions not correct
        default: return cmd.hasPrefix("AT") ? ["OK"] : negative(0x7F) } }
    var ticks: [[Int]] = []
    let data = try await sweep(link, ids(3)) { ticks.append([$0, $1]) }
    #expect(data.isEmpty)
    #expect(link.sent.filter { !$0.hasPrefix("AT") } == [
        readRequest(0x3000), "56 02 10 03 00 00 00 00", readRequest(0x3001), readRequest(0x3002)])
    #expect(ticks == [[1, 3], [2, 3], [3, 3]])
}
@Test func anAnswerOfAnyKindRestartsTheCountOfSilentIdentifiers() async throws {
    // Four silent, a positive, four silent, a negative, four silent: never five in a row.
    let spaced = "ssssp" + "ssssn" + "ssss"
    #expect(try await sweep(answering(spaced), ids(spaced.count)) == [0x3004: [0xAA]])
    // Five in a row after an answer still stop it, `after` counting every identifier asked so far.
    let stopped = "ssssn" + "sssss"
    await #expect(throws: CodingError.moduleStoppedAnswering(after: 10)) {
        _ = try await sweep(answering(stopped), ids(stopped.count)) }
}
@Test func testerPresentGoesOutOnlyBeforeAReadMoreThanTwoSecondsAfterTheLastRequest() async throws {
    let start = ContinuousClock.now
    var elapsed = Duration.zero
    // The time that passes after each identifier (a read itself takes none): the first is exactly two seconds, and
    // the last two are each under two seconds but together over.
    let waits: [Duration] = [
        .milliseconds(2000), .milliseconds(2500), .milliseconds(100), .milliseconds(3000), .milliseconds(1500),
        .milliseconds(1500), .zero]
    // TesterPresent goes unanswered, which must not matter.
    let link = FakeLink { cmd in
        cmd.hasPrefix("AT") ? ["OK"] : cmd.hasPrefix("56 03 22") ? negative(0x31) : ["NO DATA"] }
    let data = try await Coding.read(diag: Diag(link: link, log: Log()), module: 0x56, dids: ids(7),
                                     now: { start + elapsed }) { done, _ in elapsed += waits[done - 1] }
    #expect(data.isEmpty)
    let tester = "56 02 3E 00 00 00 00 00"
    #expect(link.sent.filter { !$0.hasPrefix("AT") } == [
        readRequest(0x3000), readRequest(0x3001), tester, readRequest(0x3002), readRequest(0x3003), tester,
        readRequest(0x3004), readRequest(0x3005), readRequest(0x3006)])
}
@Test func cancellingStopsTheSweepBetweenTwoIdentifiers() async {
    var task: Task<[UInt16: [UInt8]], any Error>?
    let link = FakeLink { cmd in
        if cmd == readRequest(0x3002) { task?.cancel() }  // while the third read is in flight
        return cmd.hasPrefix("AT") ? ["OK"] : negative(0x31) }
    task = Task { try await sweep(link, ids(10)) }
    await #expect(throws: CancellationError.self) { _ = try await task?.value }
    #expect(link.sent.filter { !$0.hasPrefix("AT") } ==
            [readRequest(0x3000), readRequest(0x3001), readRequest(0x3002)])
}
@Test func aLinkErrorEndsTheSweepInsteadOfBeingSkipped() async {
    var reads = 0
    let link = FakeLink { cmd in
        guard cmd.hasPrefix("56 03 22") else { return ["OK"] }
        reads += 1
        if reads == 2 { throw LinkError.disconnected }
        return negative(0x31) }
    var done = 0
    await #expect(throws: LinkError.disconnected) { _ = try await sweep(link, ids(5)) { n, _ in done = n } }
    #expect(reads == 2)  // the third identifier was never asked
    #expect(done == 1)
}

@Test func rememberReplacesTheSetOfThatKeyAndLeavesTheOthers() {
    var sets = RememberedSets(sets: [:])
    sets.remember([0x3000, 0x3001], address: 0x56, codingFiles: ["A"])
    sets.remember([0x3005], address: 0x40, codingFiles: ["A"])
    sets.remember([0x3002], address: 0x56, codingFiles: ["A"])
    #expect(sets.dids(address: 0x56, codingFiles: ["A"]) == [0x3002])
    #expect(sets.dids(address: 0x40, codingFiles: ["A"]) == [0x3005])
    #expect(sets.sets.count == 2)
}
@Test func theKeyHasTwoUpperCaseHexDigitsAndASetIsFoundOnlyForTheSameAddressAndFiles() {
    #expect(RememberedSets.key(address: 0x05, codingFiles: ["A"]) == "05|A")
    #expect(RememberedSets.key(address: 0xAB, codingFiles: ["A"]) == "AB|A")
    #expect(RememberedSets.key(address: 0x56, codingFiles: []) == "56|")
    var sets = RememberedSets(sets: [:])
    sets.remember([0x3000], address: 0x56, codingFiles: ["B", "A"])
    #expect(sets.dids(address: 0x56, codingFiles: ["A", "B"]) == [0x3000])  // whatever order the files come in
    #expect(sets.dids(address: 0x57, codingFiles: ["A", "B"]) == nil)
    #expect(sets.dids(address: 0x56, codingFiles: ["A"]) == nil)
}
@Test func aMissingOrUndecodableFileLoadsAsEmpty() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sets-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(RememberedSets.load(from: url).sets.isEmpty)
    for text in ["", "not json", "[]", "{\"sets\": 5}", "{\"sets\": {\"56|A\": [\"x\"]}}"] {
        try Data(text.utf8).write(to: url)
        #expect(RememberedSets.load(from: url).sets.isEmpty, "\(text)")
    }
}
@Test func theRememberedSetsFileHoldsPrettyPrintedJSONWithSortedKeys() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sets-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    // 12288 is 0x3000. Five keys, so that keys left unsorted would show on nearly every run.
    let json = """
        {
          "sets" : {
            "10|CAFD_00000001_001_000_000" : [
              12288
            ],
            "40|CAFD_00000002_001_000_000" : [
              12288,
              12289
            ],
            "56|CAFD_000006C9_024_002_013" : [
              12288,
              12290
            ],
            "60|CAFD_00000004_001_000_000" : [
              16383
            ],
            "63|CAFD_00000005_001_000_000,CAFD_00000006_001_000_000" : [
              12304
            ]
          }
        }
        """
    try Data(json.utf8).write(to: url)
    let sets = RememberedSets.load(from: url)
    #expect(sets.sets == [
        "10|CAFD_00000001_001_000_000": [0x3000],
        "40|CAFD_00000002_001_000_000": [0x3000, 0x3001],
        "56|CAFD_000006C9_024_002_013": [0x3000, 0x3002],
        "60|CAFD_00000004_001_000_000": [0x3FFF],
        "63|CAFD_00000005_001_000_000,CAFD_00000006_001_000_000": [0x3010]])
    try sets.save(to: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == json)
}
@Test func savingRememberedSetsCreatesMissingFoldersAndReplacesAnExistingFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sets-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a/b/sets.json")
    var sets = RememberedSets(sets: [:])
    sets.remember([0x3000], address: 0x56, codingFiles: ["A"])
    try sets.save(to: url)
    sets.remember([0x3002], address: 0x63, codingFiles: ["B"])
    try sets.save(to: url)
    #expect(RememberedSets.load(from: url) == sets)
}
