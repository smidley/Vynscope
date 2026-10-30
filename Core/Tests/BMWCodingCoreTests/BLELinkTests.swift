import Testing
@testable import BMWCodingCore

@Test func replyLinesSplitOnAnyLineBreakTrimAndDropBlanksAndTheEcho() {
    // echo, blank lines, CR, LF and CRLF breaks, and stray spaces and tabs around the text
    #expect(BLELink.replyLines("ATZ\r\r  ELM327 v1.4b \r\n\n\tOK\r", dropping: "ATZ") == ["ELM327 v1.4b", "OK"])
    #expect(BLELink.replyLines("663 F1 10 14\r663 F1 21 62\r\r", dropping: "ATI") == ["663 F1 10 14", "663 F1 21 62"])
    #expect(BLELink.replyLines("\r\r", dropping: "ATI").isEmpty)
}

@Test func theKeepAliveAndTheProbeAreTheAdaptersOwnIdentify() {
    #expect(BLELink.keepAliveCommand == "ATI")  // never a bare carriage return, which repeats the last command
}
