/// What the app shows for a module it knows by address.
public struct ModuleInfo: Equatable, Sendable {
    public let name: String
    public let description: String
}

/// What the app knows about modules by diagnostic address, and which ones it must treat as signed.
public enum ModuleTable {
    /// Seed entries; the names are confirmed against the car's own answers in Task 15.
    private static let known: [UInt8: ModuleInfo] = [
        0x01: ModuleInfo(name: "ACSM_5", description: "Crash safety"),
        0x10: ModuleInfo(name: "ZGW", description: "Gateway (F-series)"),
        0x40: ModuleInfo(name: "BDC_BODY3", description: "Body controller"),
        0x56: ModuleInfo(name: "FZD__35", description: "Roof functions"),
        0x60: ModuleInfo(name: "KOMBI", description: "Instrument cluster"),
        0x63: ModuleInfo(name: "HU_MGU", description: "Head unit"),
        0x78: ModuleInfo(name: "IHKA_PRO2", description: "Climate"),
    ]

    /// The name and description of the module at `address`, or `nil` when the app has no entry for it.
    public static func info(for address: UInt8) -> ModuleInfo? { known[address] }

    /// Whether the module at `address` has signed coding, which a module rejects when it is not signed for
    /// the car's VIN. Only the i4 (VIN prefix `WBY73`) has any: its body controller, instrument cluster and
    /// head unit.
    public static func isSigned(address: UInt8, vin: String) -> Bool {
        vin.hasPrefix("WBY73") && [0x40, 0x60, 0x63].contains(address)
    }

    /// The addresses to ask for the VIN, in the order to try them.
    public static let gatewayCandidates: [UInt8] = [0x40, 0x10, 0x60, 0x63]
}
