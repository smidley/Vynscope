import Foundation

/// How a fault reads to the owner, from the ISO 14229 status byte the module returned.
public enum FaultChip: String, Sendable, CaseIterable {
    case active, pending, stored, old

    /// `statusHex` as `HealthCheck.Fault.status` holds it, two hex digits: test-failed (bit 0) is active; else pending
    /// (bit 2) is pending; else confirmed (bit 3) is stored; else old. `nil` when the text is not a byte.
    public static func chip(forStatus statusHex: String) -> FaultChip? {
        guard let status = UInt8(statusHex, radix: 16) else { return nil }
        if status & 0x01 != 0 { return .active }
        if status & 0x04 != 0 { return .pending }
        return status & 0x08 != 0 ? .stored : .old
    }
}

extension HealthCheck {
    /// Whether the read is recent enough for the mechanic to reuse: `readAt` within `maxAge` seconds of `now`.
    /// The ten minutes are the knob the design names.
    public func isFresh(at now: Date, maxAge: TimeInterval = 600) -> Bool {
        guard let date = try? Date(readAt, strategy: .iso8601) else { return false }
        return now.timeIntervalSince(date) <= maxAge
    }

    /// The read as lines the owner can send the mechanic. "I just read the fault codes:" then one line per module in
    /// order, "<label>: <code> <chip>, <code> <chip>" / "<label>: no faults" / "<label>: <faultRead>", where the label is
    /// "<name> (<address>)" or "0x<address>" without a name, and the chip of a status that is not a byte is written
    /// "status <hex>"; then "OBD stored: <codes>" and "OBD pending: <codes>" when there are any (codes
    /// comma-separated, controllers in sorted order); or the one line "no module answered" when `nothingAnswered`.
    public var faultSummary: String {
        var lines = ["I just read the fault codes:"]
        if nothingAnswered {
            lines.append("no module answered")
        } else {
            lines += modules.map { module in
                let label = module.name.map { "\($0) (\(module.address))" } ?? "0x" + module.address
                // `health(of:)` sets `faults` or `faultRead`; a module with neither reads as one that did not answer.
                guard let faults = module.faults else { return label + ": " + (module.faultRead ?? "no answer") }
                if faults.isEmpty { return label + ": no faults" }
                let chips = faults.map { fault in
                    fault.code + " " + (FaultChip.chip(forStatus: fault.status)?.rawValue ?? "status " + fault.status)
                }
                return label + ": " + chips.joined(separator: ", ")
            }
            if let obd {
                for (title, codes) in [("OBD stored", obd.storedCodes), ("OBD pending", obd.pendingCodes)] {
                    let all = codes.sorted { $0.key < $1.key }.flatMap(\.value)
                    if !all.isEmpty { lines.append(title + ": " + all.joined(separator: ", ")) }
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
