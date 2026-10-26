/// One adapter response line, classified.
public enum ELMLine: Equatable, Sendable {
    case frame(id: UInt16, data: [UInt8])
    case text(String)
    case noData
    case error(String)
}

public enum ELM {
    /// Lines the adapter prints when a request failed or was not understood.
    public static let errorTexts: Set<String> = [
        "CAN ERROR", "BUS ERROR", "BUS BUSY", "STOPPED",
        "UNABLE TO CONNECT", "?", "DATA ERROR", "BUFFER FULL",
    ]

    /// Classifies one response line (already trimmed by the link). A frame is a first token of exactly
    /// three hex digits (the CAN id, headers on) followed by tokens of exactly two hex digits.
    public static func parse(_ line: String) -> ELMLine {
        if errorTexts.contains(line) { return .error(line) }
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
