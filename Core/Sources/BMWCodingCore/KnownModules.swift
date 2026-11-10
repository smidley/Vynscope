import Foundation

/// The systems each car has been seen to have, kept in a JSON file so that a later check asks only those. The list
/// only grows: every walk of every address adds what answered and notes when it ended, and a walk that finds nothing
/// changes nothing. A file without `walked` can only come from an earlier build of this branch; it does not decode
/// and loads as empty, which costs that car one walk of every address.
public struct KnownModules: Codable, Equatable {
    /// The addresses that ever answered a walk of every address, by VIN, ascending.
    public var cars: [String: [UInt8]] = [:]
    /// When each car was last walked at every address to the end, by VIN.
    public var walked: [String: Date] = [:]

    /// How long a walk of every address stays recent: after that a check walks every address again, so a system a
    /// first walk missed is found within a month.
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// The remembered cars in the file at `url`. Empty when there is no file or it cannot be decoded, in which
    /// case the next `save` replaces it.
    public static func load(from url: URL) -> KnownModules {
        (try? JSONDecoder().decode(KnownModules.self, from: Data(contentsOf: url))) ?? KnownModules()
    }

    /// Writes the cars to `url` as pretty-printed JSON with sorted keys, creating the folders on the way. The file
    /// is replaced as a whole, so a crash half-way leaves the old one.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The addresses remembered for the car with this VIN, or `nil` when there are none.
    public func addresses(forVIN vin: String) -> [UInt8]? {
        cars[vin]
    }

    /// Whether the car with this VIN was last walked at every address at most `maxAge` before `now`. False for a
    /// car never walked.
    public func isRecent(forVIN vin: String, at now: Date, maxAge: TimeInterval = KnownModules.maxAge) -> Bool {
        guard let date = walked[vin] else { return false }
        return now.timeIntervalSince(date) <= maxAge
    }

    /// Adds `addresses`, the systems that answered a walk of every address that ended at `date`, to those the car
    /// with this VIN has, sorted and without duplicates, and notes `date` as its last such walk. An empty list
    /// changes nothing, neither the list nor the date, so a silent car never erases what was known.
    public mutating func remember(_ addresses: [UInt8], forVIN vin: String, at date: Date = .now) {
        guard !addresses.isEmpty else { return }
        // ponytail: a remembered system is never forgotten; add a Forget for a car that really lost one.
        cars[vin] = Set(addresses).union(cars[vin] ?? []).sorted()
        walked[vin] = date
    }
}
