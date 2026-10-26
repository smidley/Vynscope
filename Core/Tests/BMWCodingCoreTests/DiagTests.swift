import Testing
@testable import BMWCodingCore

@Test func setUpSendsSequenceAndReadsIdentity() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "ATZ": return ["ELM327 v1.4b"]
        case "ATI": return ["ELM327 v1.4b"]
        case "STI": return ["STN2255 v5.6.2"]
        case "STDI": return ["OBDLink CX r1.0"]
        default: return ["OK"] } }
    let info = try await Diag(link: link, log: Log()).setUp()
    #expect(info == AdapterInfo(model: "OBDLink CX r1.0", firmware: "STN2255 v5.6.2", elmVersion: "ELM327 v1.4b"))
    #expect(link.sent.prefix(2) == ["ATZ", "ATE0"])
    #expect(link.sent.contains("ATCAF0") && link.sent.contains("ATFCSM 1"))
}
@Test func selectSwitchesFilterOnce() async throws {
    let link = FakeLink { _ in ["OK"] }
    let diag = Diag(link: link, log: Log())
    try await diag.select(module: 0x63); try await diag.select(module: 0x63); try await diag.select(module: 0x10)
    #expect(link.sent == ["ATCRA 663", "ATFCSD 63 30 00 00", "ATCRA 610", "ATFCSD 10 30 00 00"])
}
@Test func readDIDSingleFrame() async throws {
    let link = FakeLink { cmd in cmd == "63 03 22 30 00 00 00 00" ? ["663 F1 05 62 30 00 01 02 00"] : ["OK"] }
    let r = try await Diag(link: link, log: Log()).readDID(0x63, 0x3000)
    #expect(r == .positive([0x01, 0x02]))
}
@Test func readDIDMultiFrameWithManualFlowControl() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "40 03 22 F1 90 00 00 00": return ["640 F1 10 14 62 F1 90 57 42"]
        case "40 30 00 00 00 00 00 00": return ["640 F1 21 59 37 33 41 57 30", "640 F1 22 34 52 46 46 41 4B", "640 F1 23 45 31 39 00 00 00"]
        default: return ["OK"] } }
    let r = try await Diag(link: link, log: Log()).readDID(0x40, 0xF190)
    #expect(r == .positive(Array("WBY73AW04RFFAKE19".utf8)))
}
@Test func negativeNoDataAndErrors() async throws {
    let neg = FakeLink { cmd in cmd.hasPrefix("63 03 22") ? ["663 F1 03 7F 22 31 00 00 00"] : ["OK"] }
    #expect(try await Diag(link: neg, log: Log()).readDID(0x63, 0x3FFF) == .negative(0x31))
    let none = FakeLink { cmd in cmd.hasPrefix("63 03") ? ["NO DATA"] : ["OK"] }
    #expect(try await Diag(link: none, log: Log()).readDID(0x63, 0x3000) == .noResponse)
    let stalled = FakeLink { cmd in cmd.hasPrefix("63 03") ? ["663 F1 10 14 62 F1 90 57 42"] : cmd.hasPrefix("63 30") ? [] : ["OK"] }
    #expect(try await Diag(link: stalled, log: Log()).readDID(0x63, 0xF190) == .noResponse)
    let bus = FakeLink { cmd in cmd.hasPrefix("63 03") ? ["CAN ERROR"] : ["OK"] }
    await #expect(throws: LinkError.adapterError("CAN ERROR")) { try await Diag(link: bus, log: Log()).readDID(0x63, 0x3000) }
}
@Test func pendingRetriesOnce() async throws {
    var calls = 0
    let link = FakeLink { cmd in
        guard cmd.hasPrefix("63 03 22") else { return ["OK"] }
        calls += 1
        return calls == 1 ? ["663 F1 03 7F 22 78 00 00 00"] : ["663 F1 04 62 30 01 AA 00 00"] }
    #expect(try await Diag(link: link, log: Log()).readDID(0x63, 0x3001) == .positive([0xAA]))
    #expect(calls == 2)
}
@Test func testerPresentAndSession() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "01 02 3E 00 00 00 00 00": return ["601 F1 02 7E 00 00 00 00 00"]
        case "01 02 10 03 00 00 00 00": return ["601 F1 06 50 03 00 32 01 F4 00"]
        default: return ["OK"] } }
    let diag = Diag(link: link, log: Log())
    #expect(try await diag.testerPresent(0x01) == true)
    #expect(try await diag.enterExtendedSession(0x01) == true)
}

// Edge cases the scenarios above do not pin down.

@Test func setUpStopsAtTheFirstCommandThatDoesNotAnswerOK() async {
    let link = FakeLink { cmd in cmd == "ATCAF0" ? ["?"] : ["OK"] }
    await #expect(throws: LinkError.adapterError("ATCAF0: ?")) { try await Diag(link: link, log: Log()).setUp() }
    #expect(link.sent.last == "ATCAF0")
}
@Test func setUpUsesEmptyStringsForIdentityTheAdapterDoesNotGive() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "ATI": return ["ELM327 v1.4b"]
        case "STI": return ["?"]  // not an STN adapter
        case "STDI": return []
        default: return ["OK"] } }
    let info = try await Diag(link: link, log: Log()).setUp()
    #expect(info == AdapterInfo(model: "", firmware: "", elmVersion: "ELM327 v1.4b"))
}
@Test func setUpForgetsTheSelectedModule() async throws {
    let link = FakeLink { _ in ["OK"] }
    let diag = Diag(link: link, log: Log())
    try await diag.select(module: 0x63)
    _ = try await diag.setUp()
    try await diag.select(module: 0x63)
    #expect(link.sent.filter { $0.hasPrefix("ATCRA") } == ["ATCRA 663", "ATCRA 663"])
}
@Test func selectWritesTheAddressAsUpperCaseTwoDigitHex() async throws {
    let link = FakeLink { _ in ["OK"] }
    let diag = Diag(link: link, log: Log())
    try await diag.select(module: 0x0A); try await diag.select(module: 0xFE); try await diag.select(module: 0x00)
    #expect(link.sent == ["ATCRA 60A", "ATFCSD 0A 30 00 00", "ATCRA 6FE", "ATFCSD FE 30 00 00",
                          "ATCRA 600", "ATFCSD 00 30 00 00"])
}
@Test func aRefusedSelectThrowsAndIsNotRemembered() async throws {
    var refuse = true
    let link = FakeLink { cmd in refuse && cmd.hasPrefix("ATFCSD") ? ["?"] : ["OK"] }
    let diag = Diag(link: link, log: Log())
    await #expect(throws: LinkError.adapterError("ATFCSD 63 30 00 00: ?")) { try await diag.select(module: 0x63) }
    refuse = false
    try await diag.select(module: 0x63)
    #expect(link.sent == ["ATCRA 663", "ATFCSD 63 30 00 00", "ATCRA 663", "ATFCSD 63 30 00 00"])
}
@Test func timeoutsAreThreeSecondsForResetTwoForSetupAndReadTimeoutForVehicleRequests() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "40 03 22 F1 90 00 00 00": return ["640 F1 10 14 62 F1 90 57 42"]
        case "40 30 00 00 00 00 00 00": return ["640 F1 21 59 37 33 41 57 30", "640 F1 22 34 52 46 46 41 4B", "640 F1 23 45 31 39 00 00 00"]
        default: return ["OK"] } }
    let diag = Diag(link: link, log: Log())
    diag.readTimeout = .milliseconds(700)
    _ = try await diag.setUp()
    try await diag.select(module: 0x40)
    _ = try await diag.readDID(0x40, 0xF190)
    #expect(link.sent.last == "40 30 00 00 00 00 00 00")  // the flow-control send is covered too
    for (command, timeout) in zip(link.sent, link.timeouts) {
        let expected: Duration = command == "ATZ" ? .seconds(3)
            : command.hasPrefix("AT") || command.hasPrefix("ST") ? .seconds(2) : .milliseconds(700)
        #expect(timeout == expected, "\(command)")
    }
}
@Test func logsEveryCommandSentAndEveryLineReceivedInOrder() async throws {
    let link = FakeLink { cmd in cmd.hasPrefix("63 03") ? ["SEARCHING...", "663 F1 04 62 30 00 AA 00 00"] : ["OK"] }
    let log = Log()
    _ = try await Diag(link: link, log: log).readDID(0x63, 0x3000)
    #expect(log.entries.map(\.direction) == [.sent, .received, .received])
    #expect(log.entries.map(\.text) == ["63 03 22 30 00 00 00 00", "SEARCHING...", "663 F1 04 62 30 00 AA 00 00"])
}
@Test(arguments: [
    "663 F1 00 00 00 00 00 00 00",  // a single frame of length 0: no service id at all
    "663 F1 01 7F 00 00 00 00 00",  // a negative answer cut off before its service echo and code
    "663 F1 02 7F 22 00 00 00 00",  // a negative answer cut off before its code
])
func answersTooShortToReadAreNoResponseWithANote(answer: String) async throws {
    let link = FakeLink { cmd in cmd.hasPrefix("63 03") ? [answer] : ["OK"] }
    let log = Log()
    #expect(try await Diag(link: link, log: log).request(0x63, [0x22, 0x30, 0x00]) == .noResponse)
    #expect(log.entries.last?.direction == .note)
}
@Test func readDIDOnlyAcceptsAPositiveThatEchoesTheIdentifier() async throws {
    let otherDID = FakeLink { cmd in cmd.hasPrefix("63 03") ? ["663 F1 04 62 30 01 AA 00 00"] : ["OK"] }
    let log = Log()
    #expect(try await Diag(link: otherDID, log: log).readDID(0x63, 0x3000) == .noResponse)
    #expect(log.entries.last?.direction == .note)
    let tooShort = FakeLink { cmd in cmd.hasPrefix("63 03") ? ["663 F1 02 62 30 00 00 00 00"] : ["OK"] }
    #expect(try await Diag(link: tooShort, log: Log()).readDID(0x63, 0x3000) == .noResponse)
    let noData = FakeLink { cmd in cmd.hasPrefix("63 03") ? ["663 F1 03 62 30 00 00 00 00"] : ["OK"] }
    #expect(try await Diag(link: noData, log: Log()).readDID(0x63, 0x3000) == .positive([]))
}
@Test func framesFromOtherModulesAndTextLinesAreIgnored() async throws {
    let link = FakeLink { cmd in
        cmd.hasPrefix("63 03") ? ["SEARCHING...", "664 F1 03 7F 22 31 00 00 00", "663 F1 04 62 30 00 AA 00 00"] : ["OK"] }
    #expect(try await Diag(link: link, log: Log()).readDID(0x63, 0x3000) == .positive([0xAA]))
}
@Test func flowControlIsSentOnlyWhenTheFirstFrameArrivesAlone() async throws {
    let link = FakeLink { cmd in
        cmd.hasPrefix("40 03")
            ? ["640 F1 10 14 62 F1 90 57 42", "640 F1 21 59 37 33 41 57 30", "640 F1 22 34 52 46 46 41 4B", "640 F1 23 45 31 39 00 00 00"]
            : ["OK"] }
    #expect(try await Diag(link: link, log: Log()).readDID(0x40, 0xF190) == .positive(Array("WBY73AW04RFFAKE19".utf8)))
    #expect(!link.sent.contains { $0.hasPrefix("40 30") })
}
@Test func aMultiFrameAnswerThatStaysIncompleteIsNoResponse() async throws {
    let ff = "640 F1 10 14 62 F1 90 57 42", cf1 = "640 F1 21 59 37 33 41 57 30"
    // part of the rest came with the first frame: there is nothing to ask for
    let early = FakeLink { cmd in cmd.hasPrefix("40 03") ? [ff, cf1] : ["OK"] }
    #expect(try await Diag(link: early, log: Log()).readDID(0x40, 0xF190) == .noResponse)
    #expect(!early.sent.contains { $0.hasPrefix("40 30") })
    // flow control brought only part of the rest
    let late = FakeLink { cmd in cmd.hasPrefix("40 03") ? [ff] : cmd.hasPrefix("40 30") ? [cf1] : ["OK"] }
    #expect(try await Diag(link: late, log: Log()).readDID(0x40, 0xF190) == .noResponse)
}
@Test func anAdapterErrorDuringFlowControlThrows() async {
    let link = FakeLink { cmd in
        cmd.hasPrefix("40 03") ? ["640 F1 10 14 62 F1 90 57 42"] : cmd.hasPrefix("40 30") ? ["BUFFER FULL"] : ["OK"] }
    await #expect(throws: LinkError.adapterError("BUFFER FULL")) { try await Diag(link: link, log: Log()).readDID(0x40, 0xF190) }
}
@Test func aSecondPendingIsReturnedAsNegativeAfterWaitingHalfASecond() async throws {
    var calls = 0
    let link = FakeLink { cmd in
        guard cmd.hasPrefix("63 03 22") else { return ["OK"] }
        calls += 1
        return ["663 F1 03 7F 22 78 00 00 00"] }
    let started = ContinuousClock.now
    #expect(try await Diag(link: link, log: Log()).readDID(0x63, 0x3001) == .negative(0x78))
    #expect(calls == 2)
    #expect(ContinuousClock.now - started >= .milliseconds(500))
}
@Test func linkErrorsPropagate() async {
    let link = FakeLink { _ in throw LinkError.disconnected }
    await #expect(throws: LinkError.disconnected) { try await Diag(link: link, log: Log()).readDID(0x63, 0x3000) }
    #expect(link.sent == ["63 03 22 30 00 00 00 00"])
}
@Test func testerPresentAndSessionAreFalseUnlessTheModuleConfirms() async throws {
    let answers = [
        ["NO DATA"],                        // silent
        ["601 F1 03 7F 10 12 00 00 00"],    // refuses
        ["601 F1 06 50 01 00 32 01 F4 00"], // answers, but with the default session
    ]
    for answer in answers {
        let link = FakeLink { cmd in cmd.hasPrefix("01 02") ? answer : ["OK"] }
        let diag = Diag(link: link, log: Log())
        #expect(try await diag.testerPresent(0x01) == false)
        #expect(try await diag.enterExtendedSession(0x01) == false)
    }
}
