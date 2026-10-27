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
    /// The entries of a module's installed-software table. First guess at the layout, to be confirmed on the car:
    /// a status byte and an entry-count byte, then 8-byte entries
    /// `[class][id, 4 bytes big-endian][main][sub][patch]`. The count byte is not trusted: every whole entry in
    /// the bytes present is read and a partial one at the end is dropped, so a payload without both header
    /// bytes has no entries.
    public static func parse(_ payload: [UInt8]) -> [SVKEntry] {
        let table = Array(payload.dropFirst(2))
        return (0..<table.count / 8).map { n in
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
