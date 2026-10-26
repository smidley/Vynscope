import Testing
@testable import BMWCodingCore

@Test func tableAndSignedList() {
    #expect(ModuleTable.info(for: 0x63)?.name == "HU_MGU")
    #expect(ModuleTable.info(for: 0x5B) == nil)
    #expect(ModuleTable.isSigned(address: 0x63, vin: "WBY73AW04RFFAKE19"))
    #expect(!ModuleTable.isSigned(address: 0x56, vin: "WBY73AW04RFFAKE19"))
    #expect(!ModuleTable.isSigned(address: 0x63, vin: "5UXWX7C5XF0K00000"))
}

// Edge cases the scenario above does not pin down.

@Test func signedIsExactlyBodyClusterAndHeadUnitOnTheI4() {
    let all = Array(UInt8.min...UInt8.max)
    #expect(all.filter { ModuleTable.isSigned(address: $0, vin: "WBY73AW04RFFAKE19") } == [0x40, 0x60, 0x63])
    #expect(all.filter { ModuleTable.isSigned(address: $0, vin: "5UXWX7C5XF0K00000") }.isEmpty)
    #expect(all.filter { ModuleTable.isSigned(address: $0, vin: "") }.isEmpty)
}
@Test func gatewayCandidatesAreTriedBodyControllerFirst() {
    #expect(ModuleTable.gatewayCandidates == [0x40, 0x10, 0x60, 0x63])
}
