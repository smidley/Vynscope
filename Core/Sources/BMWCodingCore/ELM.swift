/// One adapter response line, classified.
public enum ELMLine: Equatable, Sendable {
    case frame(id: UInt16, data: [UInt8])
    case text(String)
    case noData
    case error(String)
}

public enum ELM {
    /// Lines the adapter prints when a request failed or was not understood, and `LV RESET`, the STN's restart on
    /// low voltage.
    public static let errorTexts: Set<String> = [
        "CAN ERROR", "BUS ERROR", "BUS BUSY", "STOPPED",
        "UNABLE TO CONNECT", "?", "DATA ERROR", "BUFFER FULL", "LV RESET",
    ]

    /// Classifies one response line (already trimmed by the link). An error is one of `errorTexts` or any line
    /// with `ERROR` in it, as the STN's `FB ERROR` and `BUS INIT: ...ERROR`. A frame is a first token of exactly
    /// three hex digits (the CAN id, headers on) followed by tokens of exactly two hex digits.
    public static func parse(_ line: String) -> ELMLine {
        if errorTexts.contains(line) || line.contains("ERROR") { return .error(line) }
        if line == "NO DATA" { return .noData }
        let tokens = line.split(separator: " ")
        let id: UInt16? = tokens.first.flatMap { hex($0, digits: 3) }
        let data: [UInt8] = tokens.dropFirst().compactMap { hex($0, digits: 2) }
        // compactMap dropped nothing: every token after the id was a byte
        if let id, data.count == tokens.count - 1 { return .frame(id: id, data: data) }
        return .text(line)
    }

    /// Exactly `digits` hex digits; the digit check is needed because `init(_:radix:)` also accepts a sign.
    private static func hex<T: FixedWidthInteger>(_ token: Substring, digits: Int) -> T? {
        token.count == digits && token.allSatisfy(\.isHexDigit) ? T(token, radix: 16) : nil
    }
}

public extension ELM {
    /// Adapter setup, sent after `ATZ`; every command must answer `OK`. Echo and line feeds off, headers and
    /// spaces on (so the log and the parser see byte-separated frames), a fixed 200 ms wait for the car,
    /// 11-bit 500 kbit/s CAN with auto-formatting off (BMW's target address sits in the first data byte, so
    /// the app builds the ISO-TP frames itself), tester header `6F1`, and flow control with the user-defined
    /// frame `XX 30 00 00`, whose `XX` `Diag.select` sets per module.
    static let initSequence = [
        "ATE0", "ATL0", "ATS1", "ATH1", "ATAT0", "ATST 32", "ATSP6", "ATCAF0", "ATCFC1",
        "ATSH 6F1", "ATFCSH 6F1", "ATFCSD 00 30 00 00", "ATFCSM 1",
    ]

    /// Standard OBD-II addressing, sent by `Diag.obd` when the adapter is set up for BMW's; every command must
    /// answer `OK`. Auto-formatting on and its automatic flow-control mode (the adapter builds the ISO-TP frames
    /// and sends the flow control itself), every reply id accepted again, and the functional request header
    /// `7DF`, which every controller listens to. First guess, to be confirmed on the car.
    static let obdSequence = ["ATCAF1", "ATFCSM 0", "ATAR", "ATSH 7DF"]

    /// The way back from `obdSequence` (also a first guess), sent by `Diag.select`; every command must answer
    /// `OK`. Auto-formatting off, the user-defined flow control, and tester header `6F1` for requests and flow
    /// control again.
    static let bmwSequence = ["ATCAF0", "ATFCSM 1", "ATSH 6F1", "ATFCSH 6F1"]
}

/// Who the adapter says it is: `STDI` (the device), `STI` (its firmware) and `ATI` (the ELM327 it emulates).
public struct AdapterInfo: Equatable, Sendable {
    public let model: String
    public let firmware: String
    public let elmVersion: String
}
