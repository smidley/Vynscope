import Foundation
import Testing
@testable import BMWCodingCore

private let vin = "WBY73AW04RFFAKE19"

@Test func remembersSortedAndWithoutDuplicates() {
    var known = KnownModules(cars: [:])
    known.remember([0x78, 0x01, 0x56, 0x01], forVIN: vin)
    #expect(known.addresses(forVIN: vin) == [0x01, 0x56, 0x78])
    #expect(known.addresses(forVIN: "WBY73AW04RFFAKE20") == nil)
}

@Test func anEmptyListKeepsWhatWasRemembered() {
    var known = KnownModules(cars: [vin: [0x01]])
    known.remember([], forVIN: vin)
    #expect(known.addresses(forVIN: vin) == [0x01])
}

@Test func savesAndLoadsAndToleratesAMissingOrBrokenFile() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        .appending(path: "known-modules.json")
    #expect(KnownModules.load(from: url) == KnownModules(cars: [:]))
    var known = KnownModules(cars: [:])
    known.remember([0x56, 0x01], forVIN: vin)
    try known.save(to: url)
    #expect(KnownModules.load(from: url) == known)
    try Data("not json".utf8).write(to: url)
    #expect(KnownModules.load(from: url) == KnownModules(cars: [:]))
}
