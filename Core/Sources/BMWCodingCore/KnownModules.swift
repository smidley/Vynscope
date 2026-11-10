import Foundation

/// The addresses that answered each car's last full walk, kept in a JSON file so that a later check asks only
/// those. A walk that finds nothing leaves what was remembered as it was.
public struct KnownModules: Codable, Equatable {
    /// The addresses that answered the last full walk of each car, by VIN, ascending.
    public var cars: [String: [UInt8]]

    /// The remembered cars in the file at `url`. Empty when there is no file or it cannot be decoded, in which
    /// case the next `save` replaces it.
    public static func load(from url: URL) -> KnownModules {
        (try? JSONDecoder().decode(KnownModules.self, from: Data(contentsOf: url))) ?? KnownModules(cars: [:])
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

    /// Remembers `addresses` for the car with this VIN, sorted and without duplicates, replacing what it had. An
    /// empty list changes nothing, so a silent car never erases what was known.
    public mutating func remember(_ addresses: [UInt8], forVIN vin: String) {
        guard !addresses.isEmpty else { return }
        cars[vin] = Set(addresses).sorted()
    }
}
