import Foundation
import Testing
@testable import BMWCodingCore

private let vin = "WBY73AW04RFFAKE19"
private let walkedAt = Date(timeIntervalSince1970: 1_800_000_000)

@Test func remembersSortedAndWithoutDuplicates() {
    var known = KnownModules()
    known.remember([0x78, 0x01, 0x56, 0x01], forVIN: vin, at: walkedAt)
    #expect(known.addresses(forVIN: vin) == [0x01, 0x56, 0x78])
    #expect(known.walked[vin] == walkedAt)
    #expect(known.addresses(forVIN: "WBY73AW04RFFAKE20") == nil)
}

@Test func aLaterWalkAddsAndNeverRemoves() {
    var known = KnownModules()
    known.remember([1, 2, 3], forVIN: vin, at: walkedAt)
    let later = walkedAt.addingTimeInterval(60)
    known.remember([2, 4], forVIN: vin, at: later)
    #expect(known.addresses(forVIN: vin) == [1, 2, 3, 4])
    #expect(known.walked[vin] == later)
}

@Test func anEmptyListKeepsTheListAndTheDate() {
    var known = KnownModules()
    known.remember([0x01], forVIN: vin, at: walkedAt)
    known.remember([], forVIN: vin, at: walkedAt.addingTimeInterval(60))
    #expect(known.addresses(forVIN: vin) == [0x01])
    #expect(known.walked[vin] == walkedAt)
}

@Test func anEmptyListForACarNeverRememberedLeavesItUnknown() {
    var known = KnownModules()
    known.remember([], forVIN: vin, at: walkedAt)
    #expect(known.addresses(forVIN: vin) == nil)
    #expect(known.walked[vin] == nil)
    #expect(known == KnownModules())
}

@Test func aWalkIsRecentForThirtyDaysToTheSecond() {
    var known = KnownModules()
    known.remember([0x01], forVIN: vin, at: walkedAt)
    #expect(known.isRecent(forVIN: vin, at: walkedAt.addingTimeInterval(KnownModules.maxAge)))
    #expect(!known.isRecent(forVIN: vin, at: walkedAt.addingTimeInterval(KnownModules.maxAge + 1)))
    #expect(!known.isRecent(forVIN: "WBY73AW04RFFAKE20", at: walkedAt))
}

@Test func savesAndLoadsAndToleratesAMissingOrBrokenFile() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        .appending(path: "known-modules.json")
    #expect(KnownModules.load(from: url) == KnownModules())
    var known = KnownModules()
    known.remember([0x56, 0x01], forVIN: vin, at: walkedAt)
    try known.save(to: url)
    let loaded = KnownModules.load(from: url)
    #expect(loaded == known)
    #expect(loaded.walked[vin] == walkedAt)
    try Data("not json".utf8).write(to: url)
    #expect(KnownModules.load(from: url) == KnownModules())
}

@Test func aFileInTheOldShapeLoadsAsEmpty() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        .appending(path: "known-modules.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"cars":{"WBY73AW04RFFAKE19":[1]}}"#.utf8).write(to: url)
    #expect(KnownModules.load(from: url) == KnownModules())
}
