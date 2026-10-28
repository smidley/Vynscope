import Foundation

/// One fault a module reports: its three-byte code as six upper-case hex digits, and its status byte.
public struct DTC: Equatable, Hashable, Sendable {
    public let code: String
    public let status: UInt8
}

/// Parsers for the answers to fault-code and standard OBD-II requests. They only read bytes; none touches the adapter.
public enum DTCParse {
    /// The faults in the positive answer to `0x19 0x02`. First guess at the ISO 14229 layout, to be confirmed in the
    /// car: `0x59`, `0x02`, one availability-mask byte, then 4-byte records `[high, middle, low, status]`. A partial
    /// record at the end is dropped. `nil` unless the payload starts `59 02` and has the mask byte.
    public static func bmwFaults(_ payload: [UInt8]) -> [DTC]? {
        guard payload.count >= 3, payload[0] == 0x59, payload[1] == 0x02 else { return nil }
        return stride(from: 3, through: payload.count - 4, by: 4).map { i in
            let code = String(format: "%02X%02X%02X", payload[i], payload[i + 1], payload[i + 2])
            return DTC(code: code, status: payload[i + 3])
        }
    }

    /// The codes in the answer to mode `03` (stored) or `07` (pending) on CAN: `0x43` or `0x47`, a count byte, then
    /// 2-byte codes. The count byte is not trusted: every whole pair in the bytes present is read, and `00 00` pairs
    /// are skipped. `nil` unless the first byte is `0x43` or `0x47` and the count byte is there: a lone `43` is a
    /// garbled answer, not "no codes".
    public static func obdCodes(_ payload: [UInt8]) -> [String]? {
        guard payload.count >= 2, payload.first == 0x43 || payload.first == 0x47 else { return nil }
        return stride(from: 2, through: payload.count - 2, by: 2).compactMap { i in
            let (a, b) = (payload[i], payload[i + 1])
            return a == 0 && b == 0 ? nil : obdCode(a, b)
        }
    }

    /// A standard code like `P0420` from its two bytes: bits 7-6 of `a` pick `P`, `C`, `B` or `U`, bits 5-4 the first
    /// digit, then the low nibble of `a` and both nibbles of `b` as hex digits.
    public static func obdCode(_ a: UInt8, _ b: UInt8) -> String {
        ["P", "C", "B", "U"][Int(a >> 6)] + String(format: "%d%X%02X", (a >> 4) & 3, a & 0x0F, b)
    }

    /// The PIDs a controller supports, in order, from its answer to the mode `01` support PID `base`: `41`, `base`,
    /// then four bytes of flags, bit 7 of the first being PID `base + 1`. `nil` unless the payload is exactly that.
    /// A flag for a PID past `0xFF` is dropped, it does not fit a byte.
    public static func supportedPIDs(_ payload: [UInt8], base: UInt8) -> [UInt8]? {
        guard payload.count == 6, payload[0] == 0x41, payload[1] == base else { return nil }
        return (0..<32).compactMap { n in
            (payload[2 + n / 8] >> (7 - n % 8)) & 1 == 1 ? UInt8(exactly: Int(base) + 1 + n) : nil
        }
    }
}
