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

@Test func discoversAnsweringModules() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "63 03 22 F1 01 00 00 00": return ["663 F1 10 0D 62 F1 01 01 01", "663 F1 21 05 00 00 06 C9 18", "663 F1 22 02 0D 00 00 00 00"]
        case "63 30 00 00 00 00 00 00": return []   // consecutive frames already arrived
        case "40 03 22 F1 01 00 00 00": return ["640 F1 03 7F 22 31 00 00 00"]
        case "56 02 3E 00 00 00 00 00": return ["656 F1 02 7E 00 00 00 00 00"]
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] } }
    var found: [DiscoveredModule] = []
    for try await m in Discovery.modules(diag: Diag(link: link, log: Log()), vin: "WBY73AW04RFFAKE19", addresses: [0x40, 0x56, 0x63, 0x64]) { found.append(m) }
    #expect(found.map(\.address) == [0x40, 0x56, 0x63])
    #expect(found[0].name == "BDC_BODY3" && found[0].signed && found[0].answeredIdentification)
    #expect(found[1].name == "FZD__35" && !found[1].answeredIdentification)
    #expect(found[2].codingFiles == ["CAFD_000006C9_024_002_013"])
}

// Edge cases the scenario above does not pin down.

@Test func readsEveryIdentificationAndSplitsTheSVKIntoFields() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "63 03 22 F1 01 00 00 00":
            return ["663 F1 10 1D 62 F1 01 01 03", "663 F1 21 01 00 00 08 4D 01", "663 F1 22 00 03 08 00 00 01",
                    "663 F1 23 A2 01 00 00 05 00", "663 F1 24 00 06 C9 18 02 0D"]
        case "63 03 22 F1 8C 00 00 00": return ["663 F1 06 62 F1 8C 31 32 33"]
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] } }
    let diag = Diag(link: link, log: Log())
    var found: [DiscoveredModule] = []
    for try await m in Discovery.modules(diag: diag, vin: "WBY73AW04RFFAKE19", addresses: [0x63]) {
        found.append(m)
    }
    #expect(found.count == 1)
    let module = try #require(found.first)
    #expect(module.identification[0xF101]?.count == 26 && module.identification[0xF18C] == [0x31, 0x32, 0x33])
    #expect(module.hardware == "HWEL_0000084D_001_000_003" && module.software == "SWFL_000001A2_001_000_000")
    #expect(module.codingFiles == ["CAFD_000006C9_024_002_013"])
    #expect(link.sent.filter { $0.hasPrefix("63 03") } == ["63 03 22 F1 01 00 00 00", "63 03 22 F1 8C 00 00 00"])
}
@Test func aModuleNotInTheTableThatAnswersOnlyTesterPresentIsListedByAddress() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "5B 02 3E 00 00 00 00 00": return ["65B F1 02 7E 00 00 00 00 00"]
        case "5B 03 22 F1 8C 00 00 00": return ["65B F1 06 62 F1 8C 31 32 33"]
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] } }
    let diag = Diag(link: link, log: Log())
    var found: [DiscoveredModule] = []
    for try await m in Discovery.modules(diag: diag, vin: "WBY73AW04RFFAKE19", addresses: [0x5B]) {
        found.append(m)
    }
    #expect(found == [DiscoveredModule(address: 0x5B, name: nil, description: nil, signed: false,
                                       identification: [0xF18C: [0x31, 0x32, 0x33]], codingFiles: [],
                                       hardware: nil, software: nil, answeredIdentification: false)])
}
@Test func aLinkErrorEndsTheStreamAfterTheModulesFoundSoFar() async {
    let link = FakeLink { cmd in
        switch cmd {
        case "40 03 22 F1 01 00 00 00": return ["640 F1 03 7F 22 31 00 00 00"]
        case "ATCRA 656": throw LinkError.disconnected
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] } }
    let diag = Diag(link: link, log: Log())
    var found: [UInt8] = []
    var thrown: (any Error)?
    do {
        for try await m in Discovery.modules(diag: diag, vin: "WBY73AW04RFFAKE19", addresses: [0x40, 0x56, 0x63]) {
            found.append(m.address)
        }
    } catch { thrown = error }
    #expect(found == [0x40])
    #expect(thrown as? LinkError == .disconnected)
    #expect(!link.sent.contains("ATCRA 663"))
}
@Test func cancellingTheConsumerStopsTheProbingAfterTheAddressInFlight() async throws {
    var consumer: Task<Void, any Error>?
    let link = FakeLink { cmd in
        if cmd == "ATCRA 603" { consumer?.cancel() }
        return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] }
    consumer = Task {
        let diag = Diag(link: link, log: Log())
        for try await _ in Discovery.modules(diag: diag, vin: "WBY73AW04RFFAKE19", addresses: [1, 2, 3, 4, 5]) {}
    }
    try await consumer?.value
    #expect(link.sent.filter { $0.hasPrefix("ATCRA") } == ["ATCRA 601", "ATCRA 602", "ATCRA 603"])
}
@Test func byDefaultItProbesEveryAddressInOrderExceptTheTester() async throws {
    let link = FakeLink { cmd in cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] }
    for try await _ in Discovery.modules(diag: Diag(link: link, log: Log()), vin: "WBY73AW04RFFAKE19") {}
    let expected = (0x00...0xFF).filter { $0 != 0xF1 }
        .map { "ATCRA " + String(0x600 + $0, radix: 16, uppercase: true) }
    #expect(link.sent.filter { $0.hasPrefix("ATCRA") } == expected)
}
