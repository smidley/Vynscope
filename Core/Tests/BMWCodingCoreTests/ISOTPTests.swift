import Testing
@testable import BMWCodingCore

@Test func buildsSingleFrame() {
    #expect(ISOTP.singleFrame(to: 0x63, payload: [0x22, 0xF1, 0x90]) ==
        [0x63, 0x03, 0x22, 0xF1, 0x90, 0x00, 0x00, 0x00])
    #expect(ISOTP.hexLine([0x63, 0x03, 0x22]) == "63 03 22")
    #expect(ISOTP.flowControlFrame(to: 0x63) == [0x63, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
}
@Test func reassemblesSingleFrame() {
    #expect(ISOTP.reassemble([[0xF1, 0x04, 0x62, 0x30, 0x00, 0xAB, 0x00, 0x00]]) == .complete([0x62, 0x30, 0x00, 0xAB]))
}
@Test func reassemblesMultiFrameVIN() {
    let frames: [[UInt8]] = [
        [0xF1, 0x10, 0x14, 0x62, 0xF1, 0x90, 0x57, 0x42],
        [0xF1, 0x21, 0x59, 0x37, 0x33, 0x41, 0x57, 0x30],
        [0xF1, 0x22, 0x34, 0x52, 0x46, 0x46, 0x41, 0x4B],
        [0xF1, 0x23, 0x45, 0x31, 0x39, 0x00, 0x00, 0x00]]
    #expect(ISOTP.reassemble(frames) == .complete([0x62, 0xF1, 0x90] + Array("WBY73AW04RFFAKE19".utf8)))
}
@Test func reportsFirstFrameAloneAndIncomplete() {
    let ff: [UInt8] = [0xF1, 0x10, 0x14, 0x62, 0xF1, 0x90, 0x57, 0x42]
    #expect(ISOTP.reassemble([ff]) == .needFlowControl(expectedLength: 20))
    #expect(ISOTP.reassemble([ff, [0xF1, 0x21, 0x59, 0x37, 0x33, 0x41, 0x57, 0x30]]) == .incomplete(received: 11, expected: 20))
    #expect(ISOTP.reassemble([]) == .empty)
}
@Test func hexLineIsUpperCaseAndZeroPadded() {
    #expect(ISOTP.hexLine([0xF1, 0x0A, 0xFF]) == "F1 0A FF")
    #expect(ISOTP.hexLine([]) == "")
}
@Test func singleFrameFillsTheFrameWithSixPayloadBytes() {
    #expect(ISOTP.singleFrame(to: 0x12, payload: [1, 2, 3, 4, 5, 6]) == [0x12, 0x06, 1, 2, 3, 4, 5, 6])
}
@Test func skipsFramesTooShortToCarryAPCI() {
    // ELM.parse gives empty or one-byte data for a bare id line
    let sf: [UInt8] = [0xF1, 0x04, 0x62, 0x30, 0x00, 0xAB, 0x00, 0x00]
    #expect(ISOTP.reassemble([[], [0xF1], sf]) == .complete([0x62, 0x30, 0x00, 0xAB]))
    #expect(ISOTP.reassemble([[], [0xF1]]) == .empty)
}
@Test func malformedStartsAreReportedNotGuessed() {
    // single frame claiming 7 bytes when only 6 fit after the address and PCI
    #expect(ISOTP.reassemble([[0xF1, 0x07, 1, 2, 3, 4, 5, 6]]) == .incomplete(received: 6, expected: 7))
    // first frame cut off before its length byte
    #expect(ISOTP.reassemble([[0xF1, 0x10]]) == .empty)
    // consecutive and flow-control frames with no first frame before them
    #expect(ISOTP.reassemble([[0xF1, 0x21, 1, 2, 3, 4, 5, 6]]) == .empty)
    #expect(ISOTP.reassemble([[0xF1, 0x30, 0, 0, 0, 0, 0, 0]]) == .empty)
}
@Test func firstFrameLengthUsesAllTwelveBits() {
    // 300 = 0x12C: the high nibble 1 sits in the PCI byte, the low byte 0x2C follows
    #expect(ISOTP.reassemble([[0xF1, 0x11, 0x2C, 0x62, 0xF1, 0x90, 0x57, 0x42]]) == .needFlowControl(expectedLength: 300))
}

private let write13: [UInt8] = [0x2E, 0x30, 0x00] + Array(0x01...0x0A)

@Test func firstFrameCarriesTheLengthAndFiveBytes() {
    #expect(ISOTP.firstFrame(to: 0x56, payload: write13) == [0x56, 0x10, 0x0D, 0x2E, 0x30, 0x00, 0x01, 0x02])
}

@Test func consecutiveFramesCarrySixBytesEachFromSequenceOne() {
    #expect(ISOTP.consecutiveFrames(to: 0x56, payload: write13) == [
        [0x56, 0x21, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
        [0x56, 0x22, 0x09, 0x0A, 0x00, 0x00, 0x00, 0x00]])
}

@Test func sequenceGoesFromFBackToZero() {
    let frames = ISOTP.consecutiveFrames(to: 0x56, payload: [UInt8](repeating: 0xAB, count: 5 + 6 * 17))
    #expect(frames.map { $0[1] } == Array(0x21...0x2F) + [0x20, 0x21])
}

@Test func readsFlowControl() {
    #expect(ISOTP.flowControl([0xF1, 0x30, 0x08, 0x14, 0, 0, 0, 0])
        == ISOTP.FlowControl(status: 0, blockSize: 8, separationTime: 0x14))
    #expect(ISOTP.flowControl([0xF1, 0x32, 0x00, 0x00])?.status == 2)
    #expect(ISOTP.flowControl([0xF1, 0x03, 0x6E, 0x30]) == nil)
    #expect(ISOTP.flowControl([0xF1, 0x30, 0x00]) == nil)
}
