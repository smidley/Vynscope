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
