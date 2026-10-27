import Foundation
import Testing
@testable import BMWCodingCore

@Test func backupRoundTripAndFileName() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID())")
    let store = BackupStore(directory: dir)
    var comps = DateComponents(); comps.year = 2026; comps.month = 10; comps.day = 26; comps.hour = 14; comps.minute = 3
    let date = Calendar.current.date(from: comps)!
    let module = ModuleBackup(address: 0x56, name: "FZD__35", signed: false,
        identification: .init(partNumber: nil, hardware: "HWEL_0000084D_001_000_003", software: nil, serial: nil),
        codingFiles: ["CAFD_000006C9_024_002_013"], coding: ["3000": "AA", "3002": "0102"], method: .fullSweep, status: .complete)
    let backup = Backup(vin: "WBY73AW04RFFAKE19", nickname: "i4", date: date, appVersion: "0.1",
        adapter: .init(model: "OBDLink CX r1.0", firmware: "STN2255 v5.6.2"), modules: [module])
    let url = try store.save(backup)
    #expect(url.lastPathComponent == "2026-10-26 14-03 i4.json")
    #expect(try store.latest(forVIN: "WBY73AW04RFFAKE19") == backup)
    #expect(try store.latest(forVIN: "5UXWX7C5XF0K00000") == nil)
}
@Test func partialStatusEncodesReason() throws {
    let m = ModuleBackup(address: 0x5B, name: nil, signed: false, identification: .init(), codingFiles: [], coding: [:], method: .rememberedSet, status: .partial(reason: "module stopped answering after 5 identifiers"))
    let data = try JSONEncoder().encode(m)
    #expect(try JSONDecoder().decode(ModuleBackup.self, from: data) == m)
    #expect(String(decoding: data, as: UTF8.self).contains("stopped answering"))
}

@Test func runnerUsesRememberedSetAndRecordsMethod() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID())")
    let setsURL = dir.appendingPathComponent("sets.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var sets = RememberedSets(sets: [:]); sets.remember([0x3002], address: 0x56, codingFiles: ["CAFD_1"]); try sets.save(to: setsURL)
    let link = FakeLink { cmd in cmd == "56 03 22 30 02 00 00 00" ? ["656 F1 05 62 30 02 01 02 00"] : cmd.hasPrefix("AT") ? ["OK"] : ["656 F1 03 7F 22 31 00 00 00"] }
    let module = DiscoveredModule(address: 0x56, name: "FZD__35", description: "Roof functions", signed: false, identification: [:], codingFiles: ["CAFD_1"], hardware: nil, software: nil, answeredIdentification: true)
    let url = try await BackupRunner.run(diag: Diag(link: link, log: Log()), modules: [module], vin: "WBY73AW04RFFAKE19", nickname: "i4",
        adapter: AdapterInfo(model: "CX", firmware: "5", elmVersion: "1.4b"), appVersion: "0.1", store: BackupStore(directory: dir), setsURL: setsURL, fullRescan: false) { _ in }
    let saved = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
    #expect(saved.modules[0].method == .rememberedSet)
    #expect(saved.modules[0].coding == ["3002": "0102"])
    #expect(link.sent.filter { $0.hasPrefix("56 03 22") }.count == 1)
}
@Test func runnerAbortsWithoutFileWhenLinkDies() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var reads = 0
    let link = FakeLink { cmd in
        guard cmd.hasPrefix("56 03 22") else { return ["OK"] }
        reads += 1
        if reads == 3 { throw LinkError.disconnected }
        return ["656 F1 04 62 30 00 AA 00 00"] }
    let module = DiscoveredModule(address: 0x56, name: "FZD__35", description: nil, signed: false, identification: [:], codingFiles: [], hardware: nil, software: nil, answeredIdentification: true)
    var last: BackupProgress?
    await #expect(throws: LinkError.disconnected) {
        _ = try await BackupRunner.run(diag: Diag(link: link, log: Log()), modules: [module], vin: "V", nickname: "x", adapter: AdapterInfo(model: "", firmware: "", elmVersion: ""), appVersion: "0", store: BackupStore(directory: dir), setsURL: dir.appendingPathComponent("sets.json"), fullRescan: true) { last = $0 } }
    #expect(try BackupStore(directory: dir).list().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sets.json").path))
    #expect(last?.states[0x56] == .failed("disconnected"))
}
@Test func silentModuleIsPartialAndRunContinues() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let link = FakeLink { cmd in
        if cmd.hasPrefix("5B") { return ["NO DATA"] }
        if cmd.hasPrefix("AT") { return ["OK"] }
        return cmd == "56 03 22 30 00 00 00 00" ? ["656 F1 04 62 30 00 AA 00 00"] : ["656 F1 03 7F 22 31 00 00 00"] }
    let silent = DiscoveredModule(address: 0x5B, name: nil, description: nil, signed: false, identification: [:], codingFiles: [], hardware: nil, software: nil, answeredIdentification: false)
    let fzd = DiscoveredModule(address: 0x56, name: "FZD__35", description: nil, signed: false, identification: [:], codingFiles: [], hardware: nil, software: nil, answeredIdentification: true)
    let url = try await BackupRunner.run(diag: Diag(link: link, log: Log()), modules: [silent, fzd], vin: "V", nickname: "x", adapter: AdapterInfo(model: "", firmware: "", elmVersion: ""), appVersion: "0", store: BackupStore(directory: dir), setsURL: dir.appendingPathComponent("sets.json"), fullRescan: true) { _ in }
    let saved = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
    #expect(saved.modules[0].status == .partial(reason: "module stopped answering after 5 identifiers"))
    #expect(saved.modules[1].status == .complete)
    #expect(saved.modules[1].coding == ["3000": "AA"])
}
@Test func emptySweepIsPartial() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let link = FakeLink { cmd in cmd.hasPrefix("AT") ? ["OK"] : ["656 F1 03 7F 22 31 00 00 00"] }
    let fzd = DiscoveredModule(address: 0x56, name: "FZD__35", description: nil, signed: false, identification: [:], codingFiles: [], hardware: nil, software: nil, answeredIdentification: true)
    let url = try await BackupRunner.run(diag: Diag(link: link, log: Log()), modules: [fzd], vin: "V", nickname: "x", adapter: AdapterInfo(model: "", firmware: "", elmVersion: ""), appVersion: "0", store: BackupStore(directory: dir), setsURL: dir.appendingPathComponent("sets.json"), fullRescan: true) { _ in }
    let saved = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
    #expect(saved.modules[0].status == .partial(reason: "no coding identifiers answered"))
    #expect(RememberedSets.load(from: dir.appendingPathComponent("sets.json")).dids(address: 0x56, codingFiles: []) == nil)
}

// Edge cases the scenarios above do not pin down.

// 26 October 2026 at `hour`:`minute` local time, built the way the first scenario builds its date.
private func local(_ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: hour, minute: minute))!
}
private func sampleBackup(vin: String = "V", nickname: String = "x", at date: Date = local(14, 3),
                          appVersion: String = "0.1") -> Backup {
    Backup(vin: vin, nickname: nickname, date: date, appVersion: appVersion,
           adapter: .init(model: "CX", firmware: "5"), modules: [])
}
private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID())")
}

@Test func theNicknameIsMadeSafeForAFileName() throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BackupStore(directory: dir)
    let safe = [
        "": "car", "i4": "i4", "my.car": "my.car",
        "a/b:c": "a-b-c",                            // the two characters a file name cannot hold
        ".hidden": "-hidden", "..x": "--x",          // no leading dot
        "tab\there\nnewline\u{7F}": "tab-here-newline-",  // control characters, DEL among them
        "a/\u{301}b": "a-\u{301}b",                  // a slash with a combining mark on it is still a slash
    ]
    for (nickname, expected) in safe {
        let url = try store.save(sampleBackup(nickname: nickname))
        #expect(url.lastPathComponent == "2026-10-26 14-03 \(expected).json", "\(nickname.debugDescription)")
    }
    #expect(try store.list().count == safe.count)  // every file landed in the folder itself
}
@Test func listIsNewestFirstAndLatestSkipsOtherCarsAndUnreadableFiles() throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BackupStore(directory: dir)
    let i4 = "WBY73AW04RFFAKE19"
    let old = sampleBackup(vin: i4, at: local(14, 3), appVersion: "0.1")
    let new = sampleBackup(vin: i4, at: local(15, 0), appVersion: "0.2")
    let other = sampleBackup(vin: "5UXWX7C5XF0K00000", at: local(16, 0))
    for b in [new, old, other] { _ = try store.save(b) }  // saved in no particular order
    try Data("not json".utf8).write(to: dir.appendingPathComponent("2026-10-26 17-00 junk.json"))
    // Not backups: what the Finder leaves behind, and a file of some other kind that sorts first.
    try Data().write(to: dir.appendingPathComponent(".DS_Store"))
    try Data("notes".utf8).write(to: dir.appendingPathComponent("2026-10-26 18-00 notes.txt"))
    #expect(try store.list().map(\.lastPathComponent) == [
        "2026-10-26 17-00 junk.json", "2026-10-26 16-00 x.json", "2026-10-26 15-00 x.json", "2026-10-26 14-03 x.json"])
    #expect(try store.latest(forVIN: i4) == new)  // past the junk and the other car's, and not the older one
    #expect(try store.latest(forVIN: other.vin) == other)
}
@Test func aFolderThatDoesNotExistYetHasNoBackups() throws {
    let store = BackupStore(directory: temporaryFolder())
    #expect(try store.list().isEmpty)
    #expect(try store.latest(forVIN: "V") == nil)
}
@Test func theFileHoldsPrettyPrintedJSONWithSortedKeysAndAnISODateAnyDecoderReads() throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 1793048400 is 2026-10-26T21:00:00Z, which is a different local time in each zone, so the name is not checked.
    let date = Date(timeIntervalSince1970: 1_793_048_400)
    let module = ModuleBackup(address: 0x5B, name: nil, signed: true,
        identification: .init(partNumber: nil, hardware: "HWEL_1", software: nil, serial: "1234"),
        codingFiles: ["CAFD_1"], coding: ["3000": "AA", "3002": "0102"], method: .rememberedSet,
        status: .partial(reason: "module stopped answering after 5 identifiers"))
    let backup = Backup(vin: "V", nickname: "x", date: date, appVersion: "0.1",
        adapter: .init(model: "CX", firmware: "5"), modules: [module])
    let url = try BackupStore(directory: dir).save(backup)
    let json = """
        {
          "adapter" : {
            "firmware" : "5",
            "model" : "CX"
          },
          "appVersion" : "0.1",
          "date" : "2026-10-26T21:00:00Z",
          "modules" : [
            {
              "address" : 91,
              "coding" : {
                "3000" : "AA",
                "3002" : "0102"
              },
              "codingFiles" : [
                "CAFD_1"
              ],
              "identification" : {
                "hardware" : "HWEL_1",
                "serial" : "1234"
              },
              "method" : "rememberedSet",
              "signed" : true,
              "status" : {
                "partial" : {
                  "reason" : "module stopped answering after 5 identifiers"
                }
              }
            }
          ],
          "nickname" : "x",
          "vin" : "V"
        }
        """
    #expect(try String(contentsOf: url, encoding: .utf8) == json)
    #expect(try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url)) == backup)  // no date strategy needed
}

// `BackupRunner.run` over `link`, with the backups and the sets file (`sets.json`) in `dir`: the URL it returns.
private func runToFile(_ link: FakeLink, _ modules: [DiscoveredModule], in dir: URL, fullRescan: Bool,
                       progress: @escaping (BackupProgress) -> Void = { _ in }) async throws -> URL {
    try await BackupRunner.run(
        diag: Diag(link: link, log: Log()), modules: modules, vin: "V", nickname: "x",
        adapter: AdapterInfo(model: "CX", firmware: "5", elmVersion: "1.4b"), appVersion: "0.1",
        store: BackupStore(directory: dir), setsURL: dir.appendingPathComponent("sets.json"),
        fullRescan: fullRescan, progress: progress)
}
// What `runToFile` wrote, read back.
private func run(_ link: FakeLink, _ modules: [DiscoveredModule], in dir: URL, fullRescan: Bool,
                 progress: @escaping (BackupProgress) -> Void = { _ in }) async throws -> Backup {
    let url = try await runToFile(link, modules, in: dir, fullRescan: fullRescan, progress: progress)
    return try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
}
// A module as discovery reports it, with what a test cares about.
private func discovered(_ address: UInt8, name: String? = nil, signed: Bool = false, codingFiles: [String] = [],
                        identification: [UInt16: [UInt8]] = [:], hardware: String? = nil,
                        software: String? = nil) -> DiscoveredModule {
    DiscoveredModule(address: address, name: name, description: nil, signed: signed, identification: identification,
                     codingFiles: codingFiles, hardware: hardware, software: software, answeredIdentification: true)
}

@Test func aStalledModuleKeepsWhatItAnsweredAndOnlyACompleteFullSweepIsRemembered() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Module 0x56 has a stale remembered set, which a full rescan ignores and then replaces.
    var sets = RememberedSets(sets: [:]); sets.remember([0x3001], address: 0x56, codingFiles: [])
    try sets.save(to: dir.appendingPathComponent("sets.json"))
    let link = FakeLink { cmd in
        switch cmd {
        case "5B 03 22 30 00 00 00 00": return ["65B F1 04 62 30 00 AA 00 00"]  // one answer, then silence
        case "56 03 22 30 00 00 00 00": return ["656 F1 04 62 30 00 AA 00 00"]
        case "56 03 22 30 02 00 00 00": return ["656 F1 05 62 30 02 01 02 00"]
        case _ where cmd.hasPrefix("5B"): return ["NO DATA"]
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["656 F1 03 7F 22 31 00 00 00"]
        } }
    var last: BackupProgress?
    let saved = try await run(link, [discovered(0x5B), discovered(0x56)], in: dir, fullRescan: true) { last = $0 }
    #expect(saved.modules[0].status == .partial(reason: "module stopped answering after 6 identifiers"))
    #expect(saved.modules[0].coding == ["3000": "AA"])  // what it said before it stopped is kept
    #expect(saved.modules[1].status == .complete)
    #expect(saved.modules[1].method == .fullSweep)  // not the remembered set
    #expect(saved.modules[1].coding == ["3000": "AA", "3002": "0102"])
    #expect(link.sent.filter { $0.hasPrefix("56 03 22") }.count == Coding.fullRange.count)
    #expect(last?.states == [0x5B: .done(identifiers: 1, bytes: 1), 0x56: .done(identifiers: 2, bytes: 3)])
    let remembered = RememberedSets.load(from: dir.appendingPathComponent("sets.json"))
    #expect(remembered.dids(address: 0x56, codingFiles: []) == [0x3000, 0x3002])  // replaced, by identifier
    #expect(remembered.dids(address: 0x5B, codingFiles: []) == nil)  // a partial read is not remembered
}
@Test func aRememberedSetReadThatAnswersLessOrNothingIsPartialAndLeavesTheSetAsItWas() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    var sets = RememberedSets(sets: [:])
    sets.remember([0x3000, 0x3001], address: 0x56, codingFiles: [])  // only the first still answers
    sets.remember([0x3002], address: 0x5B, codingFiles: [])  // none still does
    let setsURL = dir.appendingPathComponent("sets.json"); try sets.save(to: setsURL)
    let link = FakeLink { cmd in
        cmd.hasPrefix("AT") ? ["OK"] : cmd == "56 03 22 30 00 00 00 00" ? ["656 F1 04 62 30 00 AA 00 00"]
            : ["6\(cmd.prefix(2)) F1 03 7F 22 31 00 00 00"] }
    let saved = try await run(link, [discovered(0x56), discovered(0x5B)], in: dir, fullRescan: false)
    #expect(saved.modules.map(\.method) == [.rememberedSet, .rememberedSet])
    #expect(saved.modules[0].coding == ["3000": "AA"])
    #expect(saved.modules[0].status == .partial(reason: "1 of 2 remembered identifiers did not answer"))
    #expect(saved.modules[1].coding.isEmpty)
    #expect(saved.modules[1].status == .partial(reason: "no coding identifiers answered"))  // not a quiet empty one
    #expect(RememberedSets.load(from: setsURL) == sets)  // only a full sweep decides what is remembered
}
@Test func aStalledRememberedSetReadKeepsTheStallReasonOverTheShortCount() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    var sets = RememberedSets(sets: [:])
    sets.remember(Array(0x3000...0x3007), address: 0x56, codingFiles: [])
    try sets.save(to: dir.appendingPathComponent("sets.json"))
    // One identifier answers, then silence: after six, with eight remembered.
    let link = FakeLink { cmd in
        cmd.hasPrefix("AT") ? ["OK"]
            : cmd == "56 03 22 30 00 00 00 00" ? ["656 F1 04 62 30 00 AA 00 00"] : ["NO DATA"] }
    let saved = try await run(link, [discovered(0x56)], in: dir, fullRescan: false)
    #expect(saved.modules[0].method == .rememberedSet)
    #expect(saved.modules[0].coding == ["3000": "AA"])
    #expect(saved.modules[0].status == .partial(reason: "module stopped answering after 6 identifiers"))
}
@Test func progressReportsEveryChangeFromWaitingThroughReadingToDone() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    var sets = RememberedSets(sets: [:])
    sets.remember([0x3000, 0x3001], address: 0x56, codingFiles: [])
    sets.remember([0x3002], address: 0x5B, codingFiles: [])
    try sets.save(to: dir.appendingPathComponent("sets.json"))
    let link = FakeLink { cmd in
        switch cmd {
        case "56 03 22 30 00 00 00 00": return ["656 F1 04 62 30 00 AA 00 00"]
        case "56 03 22 30 01 00 00 00": return ["656 F1 05 62 30 01 01 02 00"]
        case "5B 03 22 30 02 00 00 00": return ["65B F1 04 62 30 02 BB 00 00"]
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] } }
    var seen: [BackupProgress] = []
    _ = try await run(link, [discovered(0x56), discovered(0x5B)], in: dir, fullRescan: false) { seen.append($0) }
    func at(_ module: Int, _ done: Int, of total: Int, _ first: BackupProgress.ModuleState,
            _ second: BackupProgress.ModuleState) -> BackupProgress {
        BackupProgress(moduleIndex: module, moduleCount: 2, didsDone: done, didsTotal: total,
                       currentAddress: module == 0 ? 0x56 : 0x5B, states: [0x56: first, 0x5B: second])
    }
    let firstDone = BackupProgress.ModuleState.done(identifiers: 2, bytes: 3)
    #expect(seen == [
        at(0, 0, of: 2, .reading, .waiting), at(0, 1, of: 2, .reading, .waiting), at(0, 2, of: 2, .reading, .waiting),
        at(0, 2, of: 2, firstDone, .waiting),
        at(1, 0, of: 1, firstDone, .reading), at(1, 1, of: 1, firstDone, .reading),
        at(1, 1, of: 1, firstDone, .done(identifiers: 1, bytes: 1))])
}
@Test func aModulesNamesAndIdentificationGoIntoItsEntry() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    var sets = RememberedSets(sets: [:])
    sets.remember([0x3000], address: 0x56, codingFiles: ["CAFD_1"])
    for address: UInt8 in [0x5B, 0x60] { sets.remember([0x3000], address: address, codingFiles: []) }
    try sets.save(to: dir.appendingPathComponent("sets.json"))
    let link = FakeLink { cmd in cmd.hasPrefix("AT") ? ["OK"] : ["6\(cmd.prefix(2)) F1 04 62 30 00 AA 00 00"] }
    let modules = [
        // The serial is the ASCII of 0xF18C without the padding around it.
        discovered(0x56, name: "FZD__35", signed: true, codingFiles: ["CAFD_1"],
                   identification: [0xF18C: Array("  AB12\0\0".utf8)], hardware: "HWEL_1", software: "SWFL_1"),
        discovered(0x5B, identification: [0xF18C: [0x00, 0x20, 0x00]]),  // all padding: not reported
        discovered(0x60)]  // gave no serial
    let before = Date()
    let saved = try await run(link, modules, in: dir, fullRescan: false)
    #expect(saved.modules[0] == ModuleBackup(
        address: 0x56, name: "FZD__35", signed: true,
        identification: .init(partNumber: nil, hardware: "HWEL_1", software: "SWFL_1", serial: "AB12"),
        codingFiles: ["CAFD_1"], coding: ["3000": "AA"], method: .rememberedSet, status: .complete))
    #expect(saved.modules[1].identification == .init() && saved.modules[2].identification == .init())
    #expect(saved.modules.map(\.address) == [0x56, 0x5B, 0x60])  // in the order given
    #expect(saved.vin == "V" && saved.nickname == "x" && saved.appVersion == "0.1")
    #expect(saved.adapter == Backup.Adapter(model: "CX", firmware: "5"))
    #expect(abs(saved.date.timeIntervalSince(before)) < 60)  // when the run finished
}
@Test func cancellingAbortsTheRunWithNoFileButKeepsTheSetsOfTheModulesAlreadyDone() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    var task: Task<Backup, any Error>?
    let link = FakeLink { cmd in
        if cmd == "5B 03 22 30 02 00 00 00" { task?.cancel() }  // while the second module's third identifier is read
        guard !cmd.hasPrefix("AT") else { return ["OK"] }
        return cmd == "56 03 22 30 00 00 00 00" ? ["656 F1 04 62 30 00 AA 00 00"]
            : ["6\(cmd.prefix(2)) F1 03 7F 22 31 00 00 00"] }
    let modules = [discovered(0x56), discovered(0x5B), discovered(0x60)]
    var last: BackupProgress?
    task = Task { try await run(link, modules, in: dir, fullRescan: true) { last = $0 } }
    await #expect(throws: CancellationError.self) { _ = try await task?.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["sets.json"])  // and no backup
    // 0x56 was swept in full; nothing of 0x5B, which was cut short.
    #expect(RememberedSets.load(from: dir.appendingPathComponent("sets.json")).sets == ["56|": [0x3000]])
    #expect(last?.states == [0x56: .done(identifiers: 1, bytes: 1),
                             0x5B: .failed(String(describing: CancellationError())), 0x60: .waiting])
    #expect(!link.sent.contains { $0.hasPrefix("60") })  // the third module was never asked
}
@Test func aRunWhoseSetsCannotBeSavedStillWritesItsBackup() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    // A folder where the sets file belongs: it reads as no sets, and saving the sets to it fails.
    let setsURL = dir.appendingPathComponent("sets.json")
    try FileManager.default.createDirectory(at: setsURL, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try RememberedSets(sets: [:]).save(to: setsURL) }
    let link = FakeLink { cmd in
        cmd.hasPrefix("AT") ? ["OK"] : cmd == "56 03 22 30 00 00 00 00" ? ["656 F1 04 62 30 00 AA 00 00"]
            : ["656 F1 03 7F 22 31 00 00 00"] }
    let url = try await runToFile(link, [discovered(0x56)], in: dir, fullRescan: false)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(url.deletingLastPathComponent().path == dir.path)
    let saved = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))  // the file at the returned URL
    #expect(saved.modules[0].coding == ["3000": "AA"])
    #expect(saved.modules[0].status == .complete)
}
@Test func aCancelInTheLastReadOfTheLastModuleStillLeavesNoFile() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    var task: Task<Backup, any Error>?
    // The cancel comes while the last identifier of the range is read, so `Coding.read` goes on to return and
    // only the run itself can still see it.
    let link = FakeLink { cmd in
        if cmd == "56 03 22 3F FF 00 00 00" { task?.cancel() }
        return cmd.hasPrefix("AT") ? ["OK"] : cmd == "56 03 22 30 00 00 00 00" ? ["656 F1 04 62 30 00 AA 00 00"]
            : ["656 F1 03 7F 22 31 00 00 00"] }
    task = Task { try await run(link, [discovered(0x56)], in: dir, fullRescan: true) }
    await #expect(throws: CancellationError.self) { _ = try await task?.value }
    #expect(link.sent.last == "56 03 22 3F FF 00 00 00")  // the whole range was read
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["sets.json"])  // and no backup
    // It was swept in full before the cancel, so its set is kept.
    #expect(RememberedSets.load(from: dir.appendingPathComponent("sets.json")).sets == ["56|": [0x3000]])
}
@Test func aRunTheLinkDiesInKeepsTheSetsOfTheModulesSweptInFullButWritesNoFile() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 0x56 is swept in full; 0x5B answers its first identifier, and the link dies on its third.
    let link = FakeLink { cmd in
        switch cmd {
        case _ where cmd.hasPrefix("AT"): return ["OK"]
        case "56 03 22 30 00 00 00 00": return ["656 F1 04 62 30 00 AA 00 00"]
        case "5B 03 22 30 00 00 00 00": return ["65B F1 04 62 30 00 BB 00 00"]
        case "5B 03 22 30 02 00 00 00": throw LinkError.disconnected
        default: return ["6\(cmd.prefix(2)) F1 03 7F 22 31 00 00 00"]
        } }
    await #expect(throws: LinkError.disconnected) {
        _ = try await runToFile(link, [discovered(0x56), discovered(0x5B)], in: dir, fullRescan: true) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["sets.json"])  // and no backup
    #expect(RememberedSets.load(from: dir.appendingPathComponent("sets.json")).sets == ["56|": [0x3000]])
}
@Test func aModuleThatKeepsRefusingInTheSessionIsPartialWithWhatItGaveAndNotRemembered() async throws {
    let dir = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 0x56 answers 0x3000, then refuses every read and the session; 0x5B answers 0x3000 and has nothing else.
    let link = FakeLink { cmd in
        switch cmd {
        case _ where cmd.hasPrefix("AT"): return ["OK"]
        case "56 03 22 30 00 00 00 00": return ["656 F1 04 62 30 00 AA 00 00"]
        case "56 02 10 03 00 00 00 00": return ["656 F1 03 7F 10 22 00 00 00"]
        case _ where cmd.hasPrefix("56"): return ["656 F1 03 7F 22 7F 00 00 00"]
        case "5B 03 22 30 00 00 00 00": return ["65B F1 04 62 30 00 BB 00 00"]
        default: return ["65B F1 03 7F 22 31 00 00 00"]
        } }
    let saved = try await run(link, [discovered(0x56), discovered(0x5B)], in: dir, fullRescan: true)
    #expect(saved.modules[0].status == .partial(reason: "6 identifiers refused in the active session"))
    #expect(saved.modules[0].coding == ["3000": "AA"])
    #expect(saved.modules[1].status == .complete)  // the run went on
    #expect(RememberedSets.load(from: dir.appendingPathComponent("sets.json")).sets == ["5B|": [0x3000]])
}
