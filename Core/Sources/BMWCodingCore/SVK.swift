import Foundation

/// One row of a module's installed-software table: a piece of hardware, software or coding data and its version.
public struct SVKEntry: Equatable, Sendable {
    public let processClass: UInt8
    public let id: UInt32
    public let main: UInt8
    public let sub: UInt8
    public let patch: UInt8

    private static let prefixes: [UInt8: String] =
        [0x01: "HWEL", 0x02: "HWAP", 0x05: "CAFD", 0x06: "BTLD", 0x08: "SWFL"]

    /// The kind of row: `HWEL`, `CAFD` and so on, or `P` and the class in hex for a class with no name here.
    var prefix: String { Self.prefixes[processClass] ?? String(format: "P%02X", processClass) }

    /// The name BMW tools show, like `CAFD_000006C9_024_002_013`: the prefix, the id as 8 upper-case hex digits,
    /// then the main, sub and patch versions as 3-digit decimals.
    public var name: String { prefix + String(format: "_%08X_%03d_%03d_%03d", id, main, sub, patch) }
}

public enum SVK {
    /// The entries of a module's installed-software table. Confirmed on the i4 on 2026-11-04: payload bytes 2 and 3
    /// are the entry count, big-endian, and the entries are the payload's last count x 8 bytes, each
    /// `[class][id, 4 bytes big-endian][main][sub][patch]`. What sits before them is a header of varying length
    /// (17 bytes on 20 modules, 8 on 6), so the entries are counted back from the end rather than from the front.
    /// This rule fits all 26 modules read. A payload shorter than 4 bytes plus its entries has none.
    public static func parse(_ payload: [UInt8]) -> [SVKEntry] {
        guard payload.count >= 4 else { return [] }
        let count = Int(payload[2]) << 8 | Int(payload[3])
        guard payload.count >= 4 + count * 8 else { return [] }
        let table = Array(payload.suffix(count * 8))
        return (0..<count).map { n in
            let e = Array(table[n * 8..<(n + 1) * 8])
            return SVKEntry(processClass: e[0], id: e[1...4].reduce(0) { ($0 << 8) | UInt32($1) },
                            main: e[5], sub: e[6], patch: e[7])
        }
    }
}

public extension Array where Element == SVKEntry {
    /// The names of the coding files (`CAFD` entries), in table order.
    var codingFiles: [String] { filter { $0.prefix == "CAFD" }.map(\.name) }
    /// The name of the first hardware (`HWEL`) entry, or `nil` if there is none.
    var hardware: String? { first { $0.prefix == "HWEL" }?.name }
    /// The name of the first software (`SWFL`) entry, or `nil` if there is none.
    var software: String? { first { $0.prefix == "SWFL" }?.name }
}
