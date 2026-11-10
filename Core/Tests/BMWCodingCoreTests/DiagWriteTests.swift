import Testing
@testable import BMWCodingCore

// A write to module 0x56: its frames on the wire, the long listen around the frame that completes it, and nothing
// sent twice. Then the battery voltage.

/// What `select(module: 0x56)` sends, which every write begins with.
private let select56 = ["ATCRA 656", "ATFCSD 56 30 00 00"]
/// A write of `AA` to 3000, which fits one frame, and the module's positive answer to it.
private let shortWrite = "56 04 2E 30 00 AA 00 00"
private let accepted = ["656 F1 03 6E 30 00 00 00 00"]
/// The first frame of a write of `01...0A` to 3000, 13 bytes in all.
private let firstFrame13 = "56 10 0D 2E 30 00 01 02"
/// What a restoration's setup sends: the reset, the init sequence and the three identity commands.
private let setUpCommands: [String] = ["ATZ"] + ELM.initSequence + ["ATI", "STI", "STDI"]

/// Module 0x56, answering each frame in `answers` with its lines; adapter commands get `OK`, any other frame
/// `NO DATA`.
private func module56(_ answers: [String: [String]]) -> FakeLink {
    FakeLink { cmd in answers[cmd] ?? (cmd.hasPrefix("AT") || cmd.hasPrefix("ST") ? ["OK"] : ["NO DATA"]) }
}

@Test func shortWriteGoesInOneFrameInsideTheLongListen() async throws {
    let link = module56([shortWrite: accepted])
    #expect(try await Diag(link: link, log: Log()).writeDID(0x56, 0x3000, [0xAA]) == .positive([0x6E, 0x30, 0x00]))
    #expect(link.sent == select56 + ["ATST FF", shortWrite, "ATST 32"])
}
@Test func longWriteWaitsForClearToSendThenSendsEveryFrame() async throws {
    let link = module56([
        firstFrame13: ["656 F1 30 00 00 00 00 00 00"],  // clear to send, no block limit, no separation time
        "56 21 03 04 05 06 07 08": ["NO DATA"],
        "56 22 09 0A 00 00 00 00": accepted])
    #expect(try await Diag(link: link, log: Log()).writeDID(0x56, 0x3000, Array(0x01...0x0A))
        == .positive([0x6E, 0x30, 0x00]))
    #expect(link.sent == select56 + [firstFrame13, "56 21 03 04 05 06 07 08", "ATST FF", "56 22 09 0A 00 00 00 00",
                                     "ATST 32"])
}
@Test func noClearToSendMeansNoConsecutiveFrame() async throws {
    let answers = [
        ["656 F1 31 00 00 00 00 00 00"],  // wait
        ["656 F1 32 00 00 00 00 00 00"],  // overflow
        ["NO DATA"],                      // no flow control at all
    ]
    for answer in answers {
        let link = module56([firstFrame13: answer])
        #expect(try await Diag(link: link, log: Log()).writeDID(0x56, 0x3000, Array(0x01...0x0A)) == .noResponse)
        #expect(link.sent == select56 + [firstFrame13])
    }
}
@Test func blockSizeWaitsForTheNextFlowControl() async throws {
    // 15 bytes of data: a first frame and three consecutive frames, one per block.
    let clearToSendOne = ["656 F1 30 01 00 00 00 00 00"]
    let link = module56([
        "56 10 12 2E 30 00 01 02": clearToSendOne,
        "56 21 03 04 05 06 07 08": clearToSendOne,
        "56 22 09 0A 0B 0C 0D 0E": ["NO DATA"]])  // the second block's flow control is missing
    #expect(try await Diag(link: link, log: Log()).writeDID(0x56, 0x3000, Array(0x01...0x0F)) == .noResponse)
    #expect(link.sent == select56 + ["56 10 12 2E 30 00 01 02", "56 21 03 04 05 06 07 08", "56 22 09 0A 0B 0C 0D 0E"])
}
@Test func pendingThenAnswerInTheSameLinesIsTheAnswer() async throws {
    let link = module56([shortWrite: ["656 F1 03 7F 2E 78 00 00 00", "656 F1 03 6E 30 00 00 00 00"]])
    let diag = Diag(link: link, log: Log())
    #expect(try await diag.writeDID(0x56, 0x3000, [0xAA]) == .positive([0x6E, 0x30, 0x00]))
    #expect(link.sent == select56 + ["ATST FF", shortWrite, "ATST 32"])
    // The adapter listens about a second after the frame and again after the pending: two seconds more than a read.
    #expect(link.timeouts[3] == diag.readTimeout + .seconds(2))
}
@Test func aLonePendingIsNoAnswerAndNothingIsSentAgain() async throws {
    let link = module56([shortWrite: ["656 F1 03 7F 2E 78 00 00 00"]])
    #expect(try await Diag(link: link, log: Log()).writeDID(0x56, 0x3000, [0xAA]) == .noResponse)
    #expect(link.sent == select56 + ["ATST FF", shortWrite, "ATST 32"])
}
@Test func aRefusalIsItsCode() async throws {
    let link = module56([shortWrite: ["656 F1 03 7F 2E 33 00 00 00"]])
    #expect(try await Diag(link: link, log: Log()).writeDID(0x56, 0x3000, [0xAA]) == .negative(0x33))
    #expect(link.sent == select56 + ["ATST FF", shortWrite, "ATST 32"])
}
@Test func aBusyAnswerIsItsCodeAndTheWriteIsNotSentAgain() async throws {
    let link = module56([shortWrite: ["656 F1 03 7F 2E 21 00 00 00"]])
    #expect(try await Diag(link: link, log: Log()).writeDID(0x56, 0x3000, [0xAA]) == .negative(0x21))
    #expect(link.sent == select56 + ["ATST FF", shortWrite, "ATST 32"])
}
@Test func aDropOnAConsecutiveFrameIsRethrownAndNothingFollows() async throws {
    // The write of 01...0A to 3000: its first frame, then the drop on the consecutive frame in the middle of the
    // request, then on the one that completes it, inside the long listen.
    let middle = "56 21 03 04 05 06 07 08", completing = "56 22 09 0A 00 00 00 00"
    let cuts: [(Int, [String])] = [
        (4, select56 + [firstFrame13, middle]),
        (6, select56 + [firstFrame13, middle, "ATST FF", completing]),
    ]
    for (dropAfter, sent) in cuts {
        let link = module56([firstFrame13: ["656 F1 30 00 00 00 00 00 00"]])
        link.dropAfter = dropAfter
        await #expect(throws: LinkError.reconnected) {
            try await Diag(link: link, log: Log()).writeDID(0x56, 0x3000, Array(0x01...0x0A))
        }
        #expect(link.sent == sent)  // each frame once, and nothing after the cut
    }
}
@Test func aDropDuringTheWriteIsRethrownAndTheNextOperationRestores() async throws {
    let read = "56 03 22 30 00 00 00 00"
    let link = module56([read: ["656 F1 04 62 30 00 AA 00 00"]])
    let diag = Diag(link: link, log: Log())
    link.dropAfter = 4  // the select's two commands, ATST FF, then the write frame
    await #expect(throws: LinkError.reconnected) { try await diag.writeDID(0x56, 0x3000, [0xAA]) }
    #expect(try await diag.readDID(0x56, 0x3000) == .positive([0xAA]))
    // The write went once; the read restored the adapter and put module 56 back before it went.
    #expect(link.sent == select56 + ["ATST FF", shortWrite] + setUpCommands + select56 + [read])
}
@Test func aTimeoutOnTheWriteStillEndsTheLongListen() async throws {
    let link = FakeLink { cmd in
        if cmd == shortWrite { throw LinkError.timeout }
        return ["OK"] }
    await #expect(throws: LinkError.timeout) { try await Diag(link: link, log: Log()).writeDID(0x56, 0x3000, [0xAA]) }
    #expect(link.sent == select56 + ["ATST FF", shortWrite, "ATST 32"])
}
@Test func aDropWhileEndingTheLongListenStillRestoresBeforeTheNextOperation() async throws {
    let read = "56 03 22 30 00 00 00 00"
    let link = FakeLink { cmd in
        if cmd == shortWrite { throw LinkError.timeout }
        return ["OK"] }
    let diag = Diag(link: link, log: Log())
    link.dropAfter = 5  // the select's two commands, ATST FF, the write frame, then the ATST 32 after its timeout
    await #expect(throws: LinkError.timeout) { try await diag.writeDID(0x56, 0x3000, [0xAA]) }
    _ = try await diag.readDID(0x56, 0x3000)
    // The link reports a reconnect once: the read restored the adapter and module 56 before it went.
    #expect(link.sent == select56 + ["ATST FF", shortWrite, "ATST 32"] + setUpCommands + select56 + [read])
}
@Test func batteryVoltageReadsATRV() async throws {
    let readings: [(String, Double?)] = [("12.6V", 12.6), ("11.9V", 11.9), ("?", nil)]
    for (answer, volts) in readings {
        let link = FakeLink { cmd in cmd == "ATRV" ? [answer] : ["OK"] }
        #expect(try await Diag(link: link, log: Log()).batteryVoltage() == volts)
        #expect(link.sent == ["ATRV"])
    }
}
