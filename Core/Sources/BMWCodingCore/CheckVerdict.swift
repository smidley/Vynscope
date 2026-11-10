import Foundation

/// What a fault read found, as counts and one row per system with codes: the values the Check my car card words.
public struct CheckVerdict: Equatable, Sendable {
    /// Fault codes: the systems' and the standard ones.
    public let codes: Int
    public let systemsWithCodes: Int
    /// Codes whose chip is `.active`.
    public let active: Int
    /// Systems whose fault read came back with a list, empty or not.
    public let read: Int
    /// Every other system, the remembered ones that did not answer, and the standard read when it failed.
    public let unread: Int
    public let rows: [Row]
    public let nothingAnswered: Bool

    /// No codes, every system read, and something answered: the only verdict shown in green.
    public var clean: Bool { codes == 0 && unread == 0 && !nothingAnswered }

    public struct Row: Equatable, Sendable {
        public let name: String
        public let chips: [FaultChip]
    }
}

extension HealthCheck {
    /// The read's verdict. `silent` is how many remembered systems did not answer the walk before this read; they
    /// count as unread, as does a failed standard read, so a read that missed something is never clean.
    public func verdict(silent: Int = 0) -> CheckVerdict {
        var rows: [CheckVerdict.Row] = []
        var codes = 0, active = 0, read = 0
        for module in modules {
            guard let faults = module.faults else { continue }
            read += 1
            guard !faults.isEmpty else { continue }
            let chips = faults.map { FaultChip.chip(forStatus: $0.status) }
            codes += faults.count
            active += chips.filter { $0 == .active }.count
            rows.append(.init(
                name: module.description ?? module.name ?? "System 0x" + module.address,
                chips: FaultChip.allCases.filter(chips.contains)))
        }
        if let obd {
            let stored = obd.storedCodes.values.joined(), pending = obd.pendingCodes.values.joined()
            codes += stored.count + pending.count
            if !stored.isEmpty || !pending.isEmpty {
                rows.append(.init(
                    name: "Standard codes",
                    chips: (pending.isEmpty ? [] : [.pending]) + (stored.isEmpty ? [] : [.stored])))
            }
        }
        return CheckVerdict(
            codes: codes, systemsWithCodes: rows.count, active: active, read: read,
            unread: modules.count - read + silent + (obdError == nil ? 0 : 1), rows: rows,
            nothingAnswered: nothingAnswered)
    }
}

/// The plain line for a check that stopped on an error.
public enum CheckProblem {
    public static let silentCar = "The car did not answer. Switch the ignition on and try again."

    /// What to do about `error`, in plain words. `connecting` is whether it ended the step that reaches the adapter.
    public static func line(for error: any Error, connecting: Bool) -> String {
        switch error {
        case LinkError.adapterError(let text) where text.hasPrefix("Bluetooth is off"):
            "Bluetooth is off. Switch it on and try again."
        case LinkError.adapterError("Bluetooth is not allowed for this app"):
            "Vynscope is not allowed to use Bluetooth. Allow it in Settings and try again."
        case LinkError.adapterError("This device does not support Bluetooth LE"):
            "This device has no Bluetooth LE, which the adapter needs."
        case LinkError.adapterError:
            connecting
                ? "No adapter found. Plug it in, wait for its light and try again."
                : "The adapter reported a problem. Try again."
        case LinkError.timeout: "The adapter did not answer in time. Try again."
        case LinkError.disconnected, DiagError.keptDropping:
            "The connection to the adapter was lost. Move closer and try again."
        case LinkError.reconnected: "The adapter reconnected. Try again."
        case VINError.noVIN, DiagError.carSilent: silentCar
        case DiagError.differentCar: "A different car answered. Check again to read it."
        default: "The check could not finish. Try again."
        }
    }
}
