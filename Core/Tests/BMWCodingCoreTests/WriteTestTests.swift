import Foundation
import Testing
@testable import BMWCodingCore

// The write test on a fake i4: its roof functions module, 0x56, holds AA BB in identifier 3000, and its newest
// complete backup agrees.

private let vin = "WBY73AW04RFFAKE19"
private let roofFile = "CAFD_00001D92_006_050_050"
private let climateFile = "CAFD_000051C9_004_036_002"
/// What `select(module: 0x56)` sends.
private let select56 = ["ATCRA 656", "ATFCSD 56 30 00 00"]
private let session = "56 02 10 03 00 00 00 00"
private let testerPresent = "56 02 3E 00 00 00 00 00"
/// A read of 3000, and the write of AA BB to it.
private let read3000 = "56 03 22 30 00 00 00 00"
private let write3000 = "56 05 2E 30 00 AA BB 00"
/// 26 October 2026, 21:00 UTC: when the reference backup was made.
private let backupDate = Date(timeIntervalSince1970: 1_793_048_400)

/// A module as discovery reports it.
private func module(_ address: UInt8 = 0x56, files: [String] = [roofFile], signed: Bool = false) -> DiscoveredModule {
    DiscoveredModule(address: address, name: nil, description: nil, signed: signed, identification: [:],
                     codingFiles: files, hardware: nil, software: nil, answeredIdentification: true)
}
/// The i4's module 0x56: the battery at `volts`; 3000 read as the two bytes `reads` (nothing when nil) and, once the
/// write to it has gone, as `readsBack` when one is given; the session and TesterPresent granted and the write of AA BB
/// to 3000 taken. `answers` replaces the answer to a command, and `before` sees every command first; other adapter
/// commands get OK, anything else NO DATA.
private func i4(volts: String = "12.6V", reads: String? = "AA BB", readsBack: String? = nil,
                _ answers: [String: [String]] = [:],
                before: @escaping (String) throws -> Void = { _ in }) -> FakeLink {
    var writeSent = false
    return FakeLink { cmd in
        try before(cmd)
        if cmd == write3000 { writeSent = true }
        if let answer = answers[cmd] { return answer }
        switch cmd {
        case "ATRV": return [volts]
        case read3000:
            let data = writeSent ? readsBack ?? reads : reads
            return data.map { ["656 F1 05 62 30 00 \($0) 00"] } ?? ["NO DATA"]
        case session: return ["656 F1 02 50 03 00 00 00 00"]
        case testerPresent: return ["656 F1 02 7E 00 00 00 00 00"]
        case write3000: return ["656 F1 03 6E 30 00 00 00 00"]
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"]
        } }
}
/// A backup of the i4 holding module 0x56 (or `address`) with this coding, these coding files and this status.
private func reference(coding: [String: String] = ["3000": "AABB"], files: [String] = [roofFile],
                       status: ModuleBackup.Status = .complete, address: UInt8 = 0x56,
                       vin: String = vin) -> Backup {
    Backup(vin: vin, nickname: "i4", date: backupDate, appVersion: "0.1", adapter: .init(model: "CX", firmware: "5"),
           modules: [ModuleBackup(address: address, name: "FZD__35", signed: false, identification: .init(),
                                  codingFiles: files, coding: coding, method: .rememberedSet, status: status)])
}
/// What `prepare` gives on the i4 for module 0x56 (or `address`) when it holds `data` and the battery is at `voltage`.
private func ready(_ data: [UInt16: [UInt8]] = [0x3000: [0xAA, 0xBB]], address: UInt8 = 0x56,
                   voltage: Double = 12.6) -> WriteTest.Ready {
    WriteTest.Ready(vin: vin, address: address, identifiers: data.keys.sorted(), data: data,
                    bytes: data.values.reduce(0) { $0 + $1.count }, backupDate: backupDate, voltage: voltage)
}
/// 3000 holding AA BB and 3001 holding CC.
private let two: [UInt16: [UInt8]] = [0x3000: [0xAA, 0xBB], 0x3001: [0xCC]]
private func prepare(_ link: FakeLink, reference: Backup?) async throws -> WriteTest.Preparation {
    try await WriteTest.prepare(diag: Diag(link: link, log: Log()), module: module(), vin: vin, reference: reference)
}
/// `WriteTest.run` with the clock stopped, unless `now` moves it.
private func run(_ link: FakeLink, _ ready: WriteTest.Ready, module: DiscoveredModule = module(), vin: String = vin,
                 progress: @escaping (Int, Int) -> Void = { _, _ in },
                 now: (() -> ContinuousClock.Instant)? = nil) async throws -> WriteTest.Outcome {
    let start = ContinuousClock.now
    return try await WriteTest.run(diag: Diag(link: link, log: Log()), module: module, vin: vin, ready: ready,
                                   now: now ?? { start }, progress: progress)
}
/// Whether `link` sent a write: a frame whose service is `2E`.
private func wrote(_ link: FakeLink) -> Bool { link.sent.contains { $0.contains(" 2E ") } }

@Test func eligibleOnlyForThePinnedModulesOnTheI4() {
    #expect(WriteTest.isEligible(module(0x56, files: [roofFile]), vin: vin))
    #expect(WriteTest.isEligible(module(0x78, files: [climateFile]), vin: vin))
    #expect(!WriteTest.isEligible(module(0x56, files: [climateFile]), vin: vin))  // another coding file
    #expect(!WriteTest.isEligible(module(0x56), vin: "5UXWX7C5XF0K00000"))  // another car
    #expect(!WriteTest.isEligible(module(0x40), vin: vin))  // the body controller, signed, even with the roof file
    #expect(!WriteTest.isEligible(module(0x01), vin: vin))  // the crash-safety module
    #expect(!WriteTest.isEligible(module(0x56, signed: true), vin: vin))  // signed as discovery saw it
}
@Test func prepareIsReadyWhenTheCarAgrees() async throws {
    let link = i4()
    let backup = reference()
    #expect(try await prepare(link, reference: backup) == .ready(WriteTest.Ready(
        vin: vin, address: 0x56, identifiers: [0x3000], data: [0x3000: [0xAA, 0xBB]], bytes: 2,
        backupDate: backup.date, voltage: 12.6)))
    #expect(!wrote(link))
}
@Test func prepareStopsOnADifferenceAndSendsNoWrite() async throws {
    let link = i4(reads: "AA CC")
    #expect(try await prepare(link, reference: reference())
        == .changed([WriteTest.Difference(what: "3000", backup: "AABB", now: "AACC")]))
    #expect(!wrote(link))
}
@Test func prepareStopsOnAMissingIdentifier() async throws {
    let link = i4(reads: nil)
    #expect(try await prepare(link, reference: reference())
        == .changed([WriteTest.Difference(what: "3000", backup: "AABB", now: "no answer")]))
    #expect(!wrote(link))
    // A module that stops answering ends the read early; what it gave before that still counts.
    let six = Dictionary(uniqueKeysWithValues: (0x3000...0x3005).map { (String(format: "%04X", $0), "AABB") })
    let stopping = i4()  // answers 3000 only
    #expect(try await prepare(stopping, reference: reference(coding: six)) == .changed((0x3001...0x3005).map {
        WriteTest.Difference(what: String(format: "%04X", $0), backup: "AABB", now: "no answer") }))
    #expect(!wrote(stopping))
}
@Test func prepareStopsWithoutAUsableBackup() async throws {
    let newer = "CAFD_00001D92_006_051_000"
    let cases: [(Backup?, WriteTest.Preparation)] = [
        (nil, .noBackup),
        (reference(address: 0x78), .noBackup),  // lacks the module
        (reference(status: .partial(reason: "module stopped answering after 5 identifiers")), .noBackup),
        (reference(coding: ["3000": "AABX"]), .noBackup),  // data that is not hex
        (reference(coding: ["300": "AABB"]), .noBackup),  // an identifier that is not four hex digits
        (reference(coding: [:]), .noBackup),  // nothing to write back
        (reference(vin: "5UXWX7C5XF0K00000"), .noBackup),  // another car's
        (reference(files: []), .backupTooOld),  // made before coding files could be read
        (reference(files: [newer]),
         .changed([WriteTest.Difference(what: "coding files", backup: newer, now: roofFile)])),
    ]
    for (backup, expected) in cases {
        let link = i4()
        #expect(try await prepare(link, reference: backup) == expected)
        #expect(link.sent.isEmpty)  // stopped before reading anything
    }
}
@Test func prepareStopsUnderTwelveVolts() async throws {
    #expect(try await prepare(i4(volts: "11.8V"), reference: reference()) == .lowVoltage(11.8))
    #expect(try await prepare(i4(volts: "?"), reference: reference()) == .lowVoltage(nil))
    #expect(try await prepare(i4(volts: "12.0V"), reference: reference()) == .ready(ready(voltage: 12.0)))  // not under
}
@Test func runWritesEachIdentifierOnceThenReadsItBack() async throws {
    let link = i4()
    var ticks: [[Int]] = []
    #expect(try await run(link, ready()) { ticks.append([$0, $1]) }
        == WriteTest.Outcome(written: 1, total: 1, end: .accepted))
    #expect(link.sent == ["ATRV"] + select56 + [session, read3000, "ATST FF", write3000, "ATST 32", read3000])
    #expect(ticks == [[1, 1]])
}
@Test func runStopsWhenAnIdentifierChangedSincePrepare() async throws {
    // Read again just before its write, 3000 holds AA CC where prepare read AA BB.
    let changed = i4(reads: "AA CC")
    #expect(try await run(changed, ready()) == WriteTest.Outcome(
        written: 0, total: 1, end: .changed(identifier: 0x3000, prepared: [0xAA, 0xBB], now: [0xAA, 0xCC])))
    #expect(!wrote(changed))
    // A read that gets no answer, or a negative one, stops the run as no answer, with nothing written either.
    let noAnswer = WriteTest.Outcome(written: 0, total: 1, end: .noAnswer(identifier: 0x3000))
    let silent = i4(reads: nil)
    #expect(try await run(silent, ready()) == noAnswer)
    #expect(!wrote(silent))
    let refusing = i4([read3000: ["656 F1 03 7F 22 31 00 00 00"]])
    #expect(try await run(refusing, ready()) == noAnswer)
    #expect(!wrote(refusing))
    // Each identifier is read again before its own write: 3000 is written back, then 3001 has changed.
    let second = i4(["56 03 22 30 01 00 00 00": ["656 F1 04 62 30 01 DD 00 00"]])
    #expect(try await run(second, ready(two)) == WriteTest.Outcome(
        written: 1, total: 2, end: .changed(identifier: 0x3001, prepared: [0xCC], now: [0xDD])))
    #expect(second.sent.filter { $0.contains(" 2E ") } == [write3000])
}
@Test func runStopsAtTheFirstRefusal() async throws {
    let refusing = i4([write3000: ["656 F1 03 7F 2E 33 00 00 00"]])
    #expect(try await run(refusing, ready(two))
        == WriteTest.Outcome(written: 0, total: 2, end: .refused(identifier: 0x3000, code: 0x33)))
    #expect(refusing.sent.filter { $0.contains(" 2E ") } == [write3000])  // the second identifier is never written
    #expect(refusing.sent.last == "ATST 32")  // nor the first read back
    // No answer to the write stops the run the same way.
    let silent = i4([write3000: ["NO DATA"]])
    #expect(try await run(silent, ready(two))
        == WriteTest.Outcome(written: 0, total: 2, end: .noAnswer(identifier: 0x3000)))
    #expect(silent.sent.last == "ATST 32")
}
@Test func runStopsOnAReadBackThatDiffers() async throws {
    let link = i4(readsBack: "AA CC")
    #expect(try await run(link, ready(two)) == WriteTest.Outcome(
        written: 0, total: 2, end: .mismatch(identifier: 0x3000, written: [0xAA, 0xBB], readBack: [0xAA, 0xCC])))
    #expect(link.sent.last == read3000)  // the second identifier is never written
}
@Test func runSendsNothingForAnIneligibleModule() async throws {
    let cases: [(DiscoveredModule, String, WriteTest.Ready)] = [
        (module(0x40), vin, ready(address: 0x40)),  // the body controller, signed, with the roof file
        (module(files: ["CAFD_00000001_001_000_000"]), vin, ready()),  // another coding file
        (module(signed: true), vin, ready()),  // signed as discovery saw it, though pinned
        (module(), "5UXWX7C5XF0K00000", ready()),  // another car
        (module(), vin, ready(address: 0x78)),  // prepared for another module
    ]
    for (module, vin, ready) in cases {
        let link = i4()
        #expect(try await run(link, ready, module: module, vin: vin)
            == WriteTest.Outcome(written: 0, total: 1, end: .notEligible))
        #expect(link.sent.isEmpty)
    }
}
@Test func runSendsNothingWithAReadyPreparedOnAnotherCar() async throws {
    guard case .ready(let prepared) = try await prepare(i4(), reference: reference()) else {
        Issue.record("the i4 agrees with its backup, so prepare should be ready")
        return
    }
    // Another i4, whose roof functions module reports the same coding file: eligible, but not the car of the bytes.
    let link = i4()
    #expect(try await run(link, prepared, vin: "WBY73AW04RFFAKE20")
        == WriteTest.Outcome(written: 0, total: 1, end: .notEligible))
    #expect(link.sent.isEmpty)
}
@Test func runWritesNothingUnderTwelveVoltsOrWithoutTheSession() async throws {
    let low = i4(volts: "11.8V")
    #expect(try await run(low, ready()) == WriteTest.Outcome(written: 0, total: 1, end: .lowVoltage(11.8)))
    #expect(low.sent == ["ATRV"])
    let refused = i4([session: ["656 F1 03 7F 10 22 00 00 00"]])
    #expect(try await run(refused, ready()) == WriteTest.Outcome(written: 0, total: 1, end: .sessionRefused))
    #expect(refused.sent == ["ATRV"] + select56 + [session])
}
@Test func runHoldsTheSessionWithTesterPresent() async throws {
    let start = ContinuousClock.now
    var elapsed = Duration.zero
    // Every request to the module takes three seconds.
    let link = i4(before: { cmd in if cmd.hasPrefix("56 ") { elapsed += .seconds(3) } })
    #expect(try await run(link, ready(), now: { start + elapsed }).end == .accepted)
    #expect(link.sent.filter { $0.hasPrefix("56 ") }
        == [session, testerPresent, read3000, testerPresent, write3000, testerPresent, read3000])
}
@Test func stopEndsTheRunBetweenTwoIdentifiersNeverInsideOne() async {
    var task: Task<WriteTest.Outcome, any Error>?
    var ticks: [[Int]] = []
    let link = i4(before: { cmd in
        if Task.isCancelled { throw CancellationError() }  // as the Bluetooth link's waits end in a cancelled task
        if cmd == write3000 { task?.cancel() }  // Stop, while the first identifier is written
    })
    task = Task { try await run(link, ready(two)) { ticks.append([$0, $1]) } }
    await #expect(throws: CancellationError.self) { _ = try await task?.value }
    #expect(ticks == [[1, 2]])  // the first identifier was read back and counted
    #expect(link.sent.last == read3000)  // and the second never written
}
@Test func aRestorationDuringTheRunEndsItBeforeTheNextWrite() async throws {
    // The link drops on the read-back of 3000, which the restored adapter reads again. 3001 still holds CC, but the
    // module has most likely left the extended session during the restoration, so it is not written.
    let link = i4(["56 03 22 30 01 00 00 00": ["656 F1 04 62 30 01 CC 00 00"]])
    link.dropAfter = 9  // ATRV, the select's two commands, the session, 3000's read, ATST FF, write, ATST 32, read-back
    var ticks: [[Int]] = []
    await #expect(throws: LinkError.reconnected) { try await run(link, ready(two)) { ticks.append([$0, $1]) } }
    #expect(ticks == [[1, 2]])  // 3000 was read back identical and counted
    #expect(link.sent.filter { $0.contains(" 2E ") } == [write3000])
}
@Test func aDropOnTheWriteIsRethrownAndTheWriteIsNotSentAgain() async throws {
    var ticks: [[Int]] = []
    let link = i4(before: { cmd in if cmd == write3000 { throw LinkError.reconnected } })
    await #expect(throws: LinkError.reconnected) { try await run(link, ready(two)) { ticks.append([$0, $1]) } }
    #expect(ticks.isEmpty)  // 3000 may have been written, but it was not read back, so it is not counted
    #expect(link.sent.filter { $0.contains(" 2E ") } == [write3000])
    #expect(link.sent.last == write3000)  // no read-back, and the restoration is left to the next operation
}
@Test func describeNamesTheCommonCodes() {
    #expect(WriteTest.describe(0x33) == "needs security access")
    #expect(WriteTest.describe(0x22) == "conditions not correct")
    #expect(WriteTest.describe(0x31) == "identifier out of range")
    #expect(WriteTest.describe(0x7E) == "answer 0x7E")
    #expect(WriteTest.describe(0x05) == "answer 0x05")
    for code: UInt8 in [0x11, 0x12, 0x13, 0x21, 0x22, 0x24, 0x31, 0x33, 0x72, 0x7F] {
        #expect(!WriteTest.describe(code).hasPrefix("answer"), "0x\(String(code, radix: 16))")
    }
}
