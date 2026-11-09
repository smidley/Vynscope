import Testing
@testable import BMWCodingCore

@Test func parsesEntriesAndNames() {
    let payload: [UInt8] = [0x01, 0x01, 0x00, 0x02,
        0x05, 0x00, 0x00, 0x06, 0xC9, 0x18, 0x02, 0x0D,
        0x01, 0x00, 0x00, 0x08, 0x4D, 0x01, 0x00, 0x03]
    let entries = SVK.parse(payload)
    #expect(entries.count == 2)
    #expect(entries[0].name == "CAFD_000006C9_024_002_013")
    #expect(entries[1].name == "HWEL_0000084D_001_000_003")
    #expect(entries.codingFiles == ["CAFD_000006C9_024_002_013"])
    #expect(entries.hardware == "HWEL_0000084D_001_000_003")
    #expect(entries.software == nil)
}
private let hwel: [UInt8] = [0x01, 0x00, 0x00, 0x51, 0xC8, 0x01, 0x00, 0x00]
private let cafd: [UInt8] = [0x05, 0x00, 0x00, 0x51, 0xC9, 0x04, 0x24, 0x02]

@Test func readsTheCountAndTakesTheEntriesFromTheEnd() {
    let longHeader: [UInt8] = [0x01, 0x01, 0x00, 0x02] + [UInt8](repeating: 0xEE, count: 13)
    #expect(SVK.parse(longHeader + hwel + cafd).map(\.name)
        == ["HWEL_000051C8_001_000_000", "CAFD_000051C9_004_036_002"])
    let shortHeader: [UInt8] = [0x01, 0x01, 0x00, 0x01] + [UInt8](repeating: 0xEE, count: 4)
    #expect(SVK.parse(shortHeader + cafd).codingFiles == ["CAFD_000051C9_004_036_002"])
}

@Test func noEntriesWhenTheAnswerIsShorterThanItsCount() {
    #expect(SVK.parse([0x01, 0x01, 0x00, 0x02] + cafd).isEmpty)
    #expect(SVK.parse([0x01, 0x01, 0x00, 0x00] + cafd).isEmpty)
    #expect(SVK.parse([0x01, 0x01, 0x00]).isEmpty)
    #expect(SVK.parse([]).isEmpty)
}
@Test func namesEveryKnownClass() {
    let classes: [UInt8] = [0x01, 0x02, 0x05, 0x06, 0x08]
    let names = classes.map { SVKEntry(processClass: $0, id: 0, main: 0, sub: 0, patch: 0).name }
    #expect(names.map { $0.prefix(4) } == ["HWEL", "HWAP", "CAFD", "BTLD", "SWFL"])
}
@Test func unknownClassIsPHexAndPartsKeepFullWidth() {
    let entry = SVKEntry(processClass: 0x0A, id: 0xDEADBEEF, main: 255, sub: 0, patch: 7)
    #expect(entry.name == "P0A_DEADBEEF_255_000_007")
}
@Test func accessorsPickByClassInOrder() {
    let entries = [
        SVKEntry(processClass: 0x05, id: 0x6C9, main: 24, sub: 2, patch: 13),
        SVKEntry(processClass: 0x08, id: 0x1A2, main: 1, sub: 0, patch: 0),
        SVKEntry(processClass: 0x02, id: 0x333, main: 9, sub: 9, patch: 9),
        SVKEntry(processClass: 0x05, id: 0x6CA, main: 24, sub: 2, patch: 14),
        SVKEntry(processClass: 0x08, id: 0x1A3, main: 2, sub: 0, patch: 0),
        SVKEntry(processClass: 0x01, id: 0x84D, main: 1, sub: 0, patch: 3),
        SVKEntry(processClass: 0x01, id: 0x84E, main: 1, sub: 0, patch: 4),
    ]
    #expect(entries.codingFiles == ["CAFD_000006C9_024_002_013", "CAFD_000006CA_024_002_014"])
    #expect(entries.hardware == "HWEL_0000084D_001_000_003")
    #expect(entries.software == "SWFL_000001A2_001_000_000")
}
