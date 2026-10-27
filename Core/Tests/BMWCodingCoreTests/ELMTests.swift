import Testing
@testable import BMWCodingCore

@Test func parsesFrameWithHeader() {
    #expect(ELM.parse("663 F1 10 14 62 F1 90 57 42") ==
        .frame(id: 0x663, data: [0xF1, 0x10, 0x14, 0x62, 0xF1, 0x90, 0x57, 0x42]))
}
@Test func parsesStatusLines() {
    #expect(ELM.parse("NO DATA") == .noData)
    #expect(ELM.parse("CAN ERROR") == .error("CAN ERROR"))
    #expect(ELM.parse("STOPPED") == .error("STOPPED"))
    #expect(ELM.parse("?") == .error("?"))
    #expect(ELM.parse("OK") == .text("OK"))
    #expect(ELM.parse("STN2255 v5.6.2") == .text("STN2255 v5.6.2"))
}
@Test func frameNeedsThreeHexIdAndBytePairs() {
    #expect(ELM.parse("SEARCHING...") == .text("SEARCHING..."))
    #expect(ELM.parse("663 F1 1") == .text("663 F1 1"))
}
@Test func frameRejectsSignsAndNonHexTokens() {
    #expect(ELM.parse("+12 F1") == .text("+12 F1"))
    #expect(ELM.parse("663 +F") == .text("663 +F"))
    #expect(ELM.parse("663 -0") == .text("663 -0"))
    #expect(ELM.parse("66G F1") == .text("66G F1"))
}
@Test func theSTNResetAndAnyLineWithERRORAreErrors() {
    #expect(ELM.parse("LV RESET") == .error("LV RESET"))
    #expect(ELM.parse("FB ERROR") == .error("FB ERROR"))
    #expect(ELM.parse("BUS INIT: ...ERROR") == .error("BUS INIT: ...ERROR"))
    #expect(ELM.parse("ELM327 v1.4b") == .text("ELM327 v1.4b"))
    #expect(ELM.parse("OK") == .text("OK"))
}
