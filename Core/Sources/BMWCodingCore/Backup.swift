import Foundation

/// One run's backup of a car: the coding data of its modules, as `BackupStore` writes it to a file.
public struct Backup: Codable, Equatable {
    public var vin: String
    public var nickname: String
    /// When the backup was made.
    public var date: Date
    public var appVersion: String
    public var adapter: Adapter
    public var modules: [ModuleBackup]

    /// The adapter the data was read through.
    public struct Adapter: Codable, Equatable {
        public var model: String
        public var firmware: String
    }
}

/// Written by hand only for `date`, which every encoder writes as ISO 8601 text (`2026-10-26T21:03:00Z`: UTC, whole
/// seconds), so that a plain `JSONDecoder` reads a backup file, whatever its date strategy. A new field goes in the
/// keys, in `init(from:)` and in `encode(to:)`; the file test in `BackupTests` pins the shape.
extension Backup {
    private enum CodingKeys: String, CodingKey { case vin, nickname, date, appVersion, adapter, modules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            vin: container.decode(String.self, forKey: .vin),
            nickname: container.decode(String.self, forKey: .nickname),
            date: Date(container.decode(String.self, forKey: .date), strategy: .iso8601),
            appVersion: container.decode(String.self, forKey: .appVersion),
            adapter: container.decode(Adapter.self, forKey: .adapter),
            modules: container.decode([ModuleBackup].self, forKey: .modules))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vin, forKey: .vin)
        try container.encode(nickname, forKey: .nickname)
        try container.encode(date.formatted(.iso8601), forKey: .date)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(adapter, forKey: .adapter)
        try container.encode(modules, forKey: .modules)
    }
}

/// The coding data of one module, and how far it can be trusted to be everything.
public struct ModuleBackup: Codable, Equatable {
    public var address: UInt8
    public var name: String?
    /// Whether the module's coding is signed, so the app must never write it.
    public var signed: Bool
    public var identification: Identification
    public var codingFiles: [String]
    /// The data of every coding identifier the module answered, by identifier: four upper-case hex digits, as in
    /// `3002`, to the data as upper-case hex without spaces, as in `0102`.
    public var coding: [String: String]
    public var method: Method
    public var status: Status

    /// What the module said about itself; `nil` for what it did not say.
    public struct Identification: Codable, Equatable {
        public var partNumber: String?
        public var hardware: String?
        public var software: String?
        public var serial: String?
    }

    /// Which identifiers were asked for: all of `Coding.fullRange`, or the set remembered from an earlier full
    /// sweep. Kept so that a backup never claims more than it read.
    public enum Method: String, Codable { case fullSweep, rememberedSet }

    /// `complete` when the read ran to its end and found data; otherwise `partial`, with why the data may lack
    /// something.
    public enum Status: Codable, Equatable { case complete, partial(reason: String) }
}

/// The folder the backup files live in, one JSON file per run.
public struct BackupStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Writes `backup` to `yyyy-MM-dd HH-mm <nickname>.json`, the time being `backup.date` in the local time zone,
    /// as pretty-printed JSON with sorted keys, and returns the file's URL. In the nickname every `/`, `:`, control
    /// character and leading `.` becomes `-`, and an empty one becomes `car`. Creates the folder if it is
    /// missing. The file is replaced as a whole, so a crash half-way leaves the old one.
    public func save(_ backup: Backup) throws -> URL {
        // ponytail: a second backup of a car under the same nickname in the same minute replaces the first. Count up
        // in the name if that ever loses a run.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(of: backup))
        try encoder.encode(backup).write(to: url, options: .atomic)
        return url
    }

    /// The backup files in the folder, newest first: the `.json` files by name, last name first, as every name
    /// starts with its time. Empty when the folder does not exist yet.
    public func list() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The newest backup of the car with this VIN, or `nil` when there is none. A file that cannot be read or
    /// decoded is passed over, as is one for another car.
    public func latest(forVIN vin: String) throws -> Backup? {
        for url in try list() {
            guard let backup = try? JSONDecoder().decode(Backup.self, from: Data(contentsOf: url)) else { continue }
            if backup.vin == vin { return backup }
        }
        return nil
    }

    private func fileName(of backup: Backup) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")  // fixed digits and calendar, whatever the region settings
        time.dateFormat = "yyyy-MM-dd HH-mm"
        // By unicode scalar, not by character: a "/" with a combining mark on it is one character, still a slash.
        var leading = true  // still among the dots the nickname starts with
        let safe = backup.nickname.unicodeScalars.map { scalar -> Unicode.Scalar in
            leading = leading && scalar == "."
            let unsafe = leading || scalar == "/" || scalar == ":" || scalar.properties.generalCategory == .control
            return unsafe ? "-" : scalar
        }
        let nickname = safe.isEmpty ? "car" : String(String.UnicodeScalarView(safe))
        return "\(time.string(from: backup.date)) \(nickname).json"
    }
}
