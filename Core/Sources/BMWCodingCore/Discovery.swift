/// A module that answered the probe, with what it said about itself.
public struct DiscoveredModule: Identifiable, Equatable, Sendable {
    public var id: UInt8 { address }
    public let address: UInt8
    /// From `ModuleTable`; `nil` for an address the table has no entry for.
    public let name: String?
    public let description: String?
    /// Whether the module's coding is signed (`ModuleTable.isSigned`), so the app must never write it.
    public let signed: Bool
    /// The data of every identification read the module answered positively, by identifier.
    public var identification: [UInt16: [UInt8]]
    /// From the installed-software table: the coding files, and the hardware and software versions.
    /// Empty and `nil` when the module did not give the table.
    public var codingFiles: [String]
    public var hardware: String?
    public var software: String?
    /// True when the module answered the first identification read over UDS, even with a negative response;
    /// false when it only confirmed TesterPresent.
    public var answeredIdentification: Bool
}

public enum Discovery {
    /// The installed-software table (SVK). Every address is probed with it, and its entries fill
    /// `DiscoveredModule.codingFiles`, `hardware` and `software`.
    private static let svkDID: UInt16 = 0xF101

    /// The identifiers read from every module that is there, in this order.
    public static let identificationDIDs: [UInt16] = [svkDID, 0xF18C]

    /// Walks `addresses` in order and yields each module that answers, as it answers. The stream finishes after
    /// the last address, or with the error `diag` throws. The default addresses leave out `0xF1`, the tester's
    /// own. `diag` is busy while the walk runs, so nothing else may use it; a consumer that stops early ends the
    /// walk only after the address in progress, which still uses `diag` until it is done.
    public static func modules(
        diag: Diag, vin: String, addresses: [UInt8] = Array(0x00...0xFF).filter { $0 != 0xF1 }
    ) -> AsyncThrowingStream<DiscoveredModule, Error> {
        AsyncThrowingStream { continuation in
            let walk = Task {
                do {
                    for address in addresses {
                        if Task.isCancelled { break }
                        // A fresh task does not inherit the cancel. A cancelled `Diag` call would give up
                        // half-way (its pending-answer wait throws) and leave the module's reply unread, so
                        // the address in progress is left to run to its end.
                        let found = try await Task { try await probe(address, diag: diag, vin: vin) }.value
                        if let module = found { continuation.yield(module) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in walk.cancel() }
        }
    }

    /// What the module at `address` says about itself, or `nil` when nothing answers there.
    private static func probe(_ address: UInt8, diag: Diag, vin: String) async throws -> DiscoveredModule? {
        try await diag.select(module: address)
        var identification: [UInt16: [UInt8]] = [:]
        let answered: Bool
        switch try await diag.readDID(address, svkDID) {
        case .positive(let data):
            identification[svkDID] = data
            answered = true
        case .negative:
            answered = true
        case .noResponse:
            guard try await diag.testerPresent(address) else { return nil }
            answered = false
        }
        for did in identificationDIDs where did != svkDID {
            if case .positive(let data) = try await diag.readDID(address, did) { identification[did] = data }
        }
        let table = SVK.parse(identification[svkDID] ?? [])
        let info = ModuleTable.info(for: address)
        return DiscoveredModule(
            address: address, name: info?.name, description: info?.description,
            signed: ModuleTable.isSigned(address: address, vin: vin), identification: identification,
            codingFiles: table.codingFiles, hardware: table.hardware, software: table.software,
            answeredIdentification: answered)
    }
}
