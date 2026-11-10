import Foundation

/// The write test: on one of two pinned modules of the i4, every coding identifier written back exactly as the module
/// holds it and read back, to learn whether the module accepts a write at all. It never changes the car: the bytes
/// written are a fresh read of the module, taken in the same run and agreed with by the newest backup in which the
/// module is complete, each identifier is read again just before its write, and the run stops at the first identifier
/// that has changed, is refused, gets no answer or reads back differently. `prepare` reads and compares and sends no
/// write; `run` writes, after its own checks. It is the only public way to send a write, and its bytes are never the
/// caller's: a `Ready` comes from `prepare` alone.
public enum WriteTest {
    /// The battery voltage, as the adapter measures it, under which nothing is written.
    public static let minimumVoltage = 12.0

    /// The id of the coding file each module the test may write must report, by address: the i4's roof functions
    /// module (`0x56`) and climate module (`0x78`), which reported exactly these in its scan of 2026-11-04. The coding
    /// file names the module; the address alone does not. Adding one is Scott's decision, once these have passed in
    /// the car.
    private static let pinned: [UInt8: String] = [0x56: "00001D92", 0x78: "000051C9"]

    /// Whether the write test may write `module` of the car with this VIN: on an i4 (prefix `WBY73`), a module at a
    /// pinned address that reports its pinned coding file, at any version. A module with signed coding never is,
    /// whether `ModuleTable` or discovery says so.
    public static func isEligible(_ module: DiscoveredModule, vin: String) -> Bool {
        guard vin.hasPrefix("WBY73"), !module.signed, !ModuleTable.isSigned(address: module.address, vin: vin),
              let id = pinned[module.address] else { return false }
        return module.codingFiles.contains { $0.hasPrefix("CAFD_\(id)_") }
    }

    /// A negative answer code in plain words, as "needs security access" for 0x33; "answer 0xNN" for one not named.
    public static func describe(_ code: UInt8) -> String {
        switch code {
        case 0x11: "service not supported"
        case 0x12: "sub-function not supported"
        case 0x13: "wrong message length or format"
        case 0x21: "busy"
        case 0x22: "conditions not correct"
        case 0x24: "request out of sequence"
        case 0x31: "identifier out of range"
        case 0x33: "needs security access"
        case 0x72: "general programming failure"
        case 0x7F: "not supported in the active session"
        default: String(format: "answer 0x%02X", code)
        }
    }

    /// What `prepare` found when everything agrees, for the confirmation and for `run`: the car and the module it read,
    /// the identifiers to write back, ascending, the data the fresh read gave for each, their size in bytes, the date
    /// of the backup they agree with and the battery voltage. Only `prepare` makes one outside this package, and `run`
    /// takes one only for the car and module it was made on, and writes each identifier only while the module still
    /// holds its bytes, so `run` writes nothing but a module's own bytes.
    public struct Ready: Equatable, Sendable {
        public let vin: String
        public let address: UInt8
        public let identifiers: [UInt16]
        public let data: [UInt16: [UInt8]]
        public let bytes: Int
        public let backupDate: Date
        public let voltage: Double
    }

    /// One thing that differs between the backup and the module now: `what` is "coding files" or an identifier as four
    /// hex digits, `backup` and `now` its two values, coding files joined by ", " and data as upper-case hex; `now` is
    /// "no answer" for an identifier the module did not give.
    public struct Difference: Equatable, Sendable {
        public let what: String
        public let backup: String
        public let now: String
    }

    /// What `prepare` found: ready to write, or why not.
    public enum Preparation: Equatable, Sendable {
        case ready(Ready)
        /// The module is not one the write test may write.
        case notEligible
        /// No backup of this car holds the module complete, with coding that reads as hex.
        case noBackup
        /// The backup was made before coding files could be read, so it cannot be matched to the module.
        case backupTooOld
        /// The module is not as the backup holds it: its coding files, or the identifiers listed in ascending order.
        case changed([Difference])
        /// The battery is under `minimumVoltage`; nil when the adapter could not read it.
        case lowVoltage(Double?)
    }

    /// Checks everything a write needs, stopping at the first check that fails, in this order: that `module` is
    /// eligible; that `reference`, the newest backup of this car in which the module is complete
    /// (`BackupStore.newest(forVIN:complete:)`), holds it with coding that reads as hex and with coding files; that the
    /// module's coding files are the backup's; that a fresh read of exactly the backup's identifiers gives the same
    /// bytes for every one; and that the battery is at `minimumVoltage` or over. Sends no write. The fresh read is held
    /// in the `Ready` only, never saved. `diag` is busy until this returns. A read that `Coding.read` ends early with a
    /// `CodingError` counts as what it had found; the errors of `diag`, and `CancellationError` between two reads once
    /// the task is cancelled, are thrown.
    public static func prepare(diag: Diag, module: DiscoveredModule, vin: String, reference: Backup?)
        async throws -> Preparation {
        guard isEligible(module, vin: vin) else { return .notEligible }
        // An entry with no coding is no reference: a run of it would say accepted without a single read-back.
        guard let reference, reference.vin == vin,
              let entry = reference.modules.first(where: { $0.address == module.address }), entry.status == .complete,
              !entry.coding.isEmpty, let expected = decode(entry.coding) else { return .noBackup }
        guard !entry.codingFiles.isEmpty else { return .backupTooOld }
        guard entry.codingFiles.sorted() == module.codingFiles.sorted() else {
            return .changed([Difference(what: "coding files", backup: entry.codingFiles.joined(separator: ", "),
                                        now: module.codingFiles.joined(separator: ", "))])
        }
        let identifiers = expected.keys.sorted()
        let found: [UInt16: [UInt8]]
        do {
            found = try await Coding.read(diag: diag, module: module.address, dids: identifiers) { _, _ in }
        } catch CodingError.moduleStoppedAnswering(_, let answered), CodingError.sessionRefused(_, let answered) {
            found = answered  // the rest did not answer, which the comparison reports
        }
        let differences = expected.sorted { $0.key < $1.key }.compactMap { did, bytes in
            found[did] == bytes ? nil : Difference(what: String(format: "%04X", did), backup: hex(bytes),
                                                   now: found[did].map(hex) ?? "no answer")
        }
        guard differences.isEmpty else { return .changed(differences) }
        let measured = try await diag.batteryVoltage()
        guard let voltage = measured, voltage >= minimumVoltage else { return .lowVoltage(measured) }
        return .ready(Ready(vin: vin, address: module.address, identifiers: identifiers, data: found,
                            bytes: found.values.reduce(0) { $0 + $1.count }, backupDate: reference.date,
                            voltage: voltage))
    }

    /// How a run ended, and how far it got.
    public struct Outcome: Equatable, Sendable {
        /// The identifiers written back and read back identical, from the first.
        public let written: Int
        /// The identifiers the run had to write back.
        public let total: Int
        public let end: End

        public enum End: Equatable, Sendable {
            /// Every identifier was written back and read back identical.
            case accepted
            /// Read again just before its write, `identifier` held `now` instead of the bytes `prepare` read. Nothing
            /// was written to it.
            case changed(identifier: UInt16, prepared: [UInt8], now: [UInt8])
            /// The module refused the write of `identifier` with this negative answer code (see `describe`).
            case refused(identifier: UInt16, code: UInt8)
            /// The module took the write of `identifier` but read back other bytes than the ones written: its fault
            /// codes are the next thing to read.
            case mismatch(identifier: UInt16, written: [UInt8], readBack: [UInt8])
            /// `identifier` got no usable answer: to its write, to its read-back, or to its read just before the write,
            /// a negative answer included, in which case nothing was written to it.
            case noAnswer(identifier: UInt16)
            /// The module refused the extended session, so nothing was written.
            case sessionRefused
            /// The module is not eligible, or `Ready` was made for another module or on another car; nothing was sent.
            case notEligible
            /// At the start of the run the battery was under `minimumVoltage`, or could not be read; nothing was
            /// written.
            case lowVoltage(Double?)
        }
    }

    /// Writes back every identifier of `ready`, in ascending order, with the data the fresh read gave, and reads each
    /// back. Each identifier is first read again: it is written only while the module still holds the bytes `prepare`
    /// read, so a `Ready` gone stale (another coding file version since, or a module recoded by another tool) writes
    /// nothing. The next identifier goes only once the module took the write (`6E` and the identifier) and gave the
    /// same bytes back. The first change, refusal, missing answer or different read-back ends the run. Sends nothing
    /// at all unless `module` is eligible and `ready` was made for it on this car; then reads the battery again,
    /// selects the module and asks for the extended session, held with TesterPresent ahead of any request more than two
    /// seconds after the last one, as `Coding.read` holds it. `progress` gets how many identifiers are confirmed, and
    /// how many there are, after each.
    ///
    /// Each write is sent once. Stop never lands inside an identifier: its read, write and read-back run in a task the
    /// caller's cancellation does not reach, and the cancellation is checked between identifiers, where it is thrown
    /// as `CancellationError`; the identifiers confirmed are those `progress` counted. A link that drops during a read
    /// or a TesterPresent is restored by `diag`, which sends that request again, but the module has most likely left
    /// the extended session meanwhile: after such a restoration the next write is not sent, and the run throws
    /// `LinkError.reconnected`. Any other error is rethrown, and the identifier it came on, which may have been written
    /// with the module's own bytes, is not counted.
    public static func run(diag: Diag, module: DiscoveredModule, vin: String, ready: Ready,
                           progress: @escaping (Int, Int) -> Void) async throws -> Outcome {
        try await run(diag: diag, module: module, vin: vin, ready: ready, now: { ContinuousClock.now },
                      progress: progress)
    }

    /// `run` with the clock as a parameter, so that a test can move time.
    static func run(diag: Diag, module: DiscoveredModule, vin: String, ready: Ready,
                    now: @escaping () -> ContinuousClock.Instant,
                    progress: @escaping (Int, Int) -> Void) async throws -> Outcome {
        let writes = ready.data.sorted { $0.key < $1.key }  // every byte written comes from the fresh read
        let address = module.address
        func outcome(_ end: Outcome.End, written: Int = 0) -> Outcome {
            Outcome(written: written, total: writes.count, end: end)
        }
        guard isEligible(module, vin: vin), ready.vin == vin, ready.address == address else {
            return outcome(.notEligible)
        }
        let measured = try await diag.batteryVoltage()
        guard let voltage = measured, voltage >= minimumVoltage else { return outcome(.lowVoltage(measured)) }
        try await diag.select(module: address)
        var lastRequest = now()  // the session request holds off TesterPresent like any other
        guard try await diag.enterExtendedSession(address) else { return outcome(.sessionRefused) }
        let restorations = diag.restorationsBegun  // any later one means the session was most likely lost
        // TesterPresent ahead of a request that comes more than two seconds after the last one; its answer is ignored.
        func holdSession() async throws {
            if now() - lastRequest > .seconds(2) { _ = try await diag.testerPresent(address) }
            lastRequest = now()
        }
        for (written, (did, data)) in writes.enumerated() {
            try Task.checkCancellation()  // between two identifiers only
            // A task of its own, which the caller's cancellation does not reach: the Bluetooth link's waits end early
            // in a cancelled task, which would leave an identifier written and not read back.
            let failure = try await Task { () async throws -> Outcome.End? in
                // Read again just before the write, so that only bytes the module holds now are written back.
                try await holdSession()
                switch try await diag.readDID(address, did) {
                case .positive(data): break
                case .positive(let held): return .changed(identifier: did, prepared: data, now: held)
                case .negative, .noResponse: return .noAnswer(identifier: did)
                }
                try await holdSession()
                // A restoration since the session was granted (a dropped link, restored inside one of the requests
                // above) ends the run: a module out of its session would refuse the write for that, not because it
                // refuses writes.
                guard diag.restorationsBegun == restorations else { throw LinkError.reconnected }
                let answer = try await diag.writeDID(address, did, data)
                guard answer == .positive([0x6E, UInt8(did >> 8), UInt8(truncatingIfNeeded: did)]) else {
                    if case .negative(let code) = answer { return .refused(identifier: did, code: code) }
                    return .noAnswer(identifier: did)
                }
                try await holdSession()
                switch try await diag.readDID(address, did) {
                case .positive(data): return nil
                case .positive(let readBack): return .mismatch(identifier: did, written: data, readBack: readBack)
                case .negative, .noResponse: return .noAnswer(identifier: did)
                }
            }.value
            if let failure { return outcome(failure, written: written) }
            progress(written + 1, writes.count)
        }
        return outcome(.accepted, written: writes.count)
    }

    /// A backup entry's coding as data by identifier; nil when an identifier is not four hex digits or its data is
    /// not whole bytes of hex.
    private static func decode(_ coding: [String: String]) -> [UInt16: [UInt8]]? {
        var decoded: [UInt16: [UInt8]] = [:]
        for (identifier, data) in coding {
            guard identifier.count == 4, let did = bytes(identifier), let data = bytes(data) else { return nil }
            decoded[UInt16(did[0]) << 8 | UInt16(did[1])] = data
        }
        return decoded
    }

    /// Hex text as bytes, two digits each, either case; nil when it is anything else.
    private static func bytes(_ hex: String) -> [UInt8]? {
        let nibbles = hex.compactMap(\.hexDigitValue)
        guard nibbles.count == hex.count, nibbles.count.isMultiple(of: 2) else { return nil }
        return stride(from: 0, to: nibbles.count, by: 2).map { UInt8(nibbles[$0] << 4 | nibbles[$0 + 1]) }
    }

    /// Bytes as upper-case hex without spaces, as a backup holds them.
    private static func hex(_ bytes: [UInt8]) -> String { ISOTP.hexLine(bytes).filter { $0 != " " } }
}
