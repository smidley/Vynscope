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

    /// `complete` when the read ran to its end and found data, all of the remembered set if it asked for one;
    /// otherwise `partial`, with why the data may lack something.
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

/// Where a backup run stands, for the screen.
public struct BackupProgress: Equatable, Sendable {
    /// The module being read, counting from 0, and how many modules the run has.
    public var moduleIndex: Int
    public var moduleCount: Int
    /// How many identifiers of that module are done, and how many it is asked for.
    public var didsDone: Int
    public var didsTotal: Int
    public var currentAddress: UInt8
    /// What has become of each module, by address; every one is `.waiting` when the run starts.
    public var states: [UInt8: ModuleState]

    public enum ModuleState: Equatable, Sendable {
        case waiting, reading
        /// Read as far as it would go: how many identifiers answered, and how many bytes of data they hold. A
        /// module that stopped answering is done too, with what it gave; its entry in the file says it is partial.
        case done(identifiers: Int, bytes: Int)
        /// The run ended on this module, with a description of the error.
        case failed(String)
    }
}

public enum BackupRunner {
    /// The serial number, which discovery reads from every module.
    private static let serialDID: UInt16 = 0xF18C

    /// Reads the coding data of `modules`, one module after the other in the order given, and writes one backup
    /// file with `store`, whose URL it returns. `progress` gets the state after every change.
    ///
    /// A module with a set remembered in `setsURL` for its coding files is asked for only that set (method
    /// `rememberedSet`), unless `fullRescan`; any other is asked for all of `Coding.fullRange` (`fullSweep`). A
    /// module that stops answering is kept as `partial` with what it gave, and so is one that gives nothing at
    /// all or, with a remembered set, fewer identifiers than the set holds; the run goes on with the next module.
    /// Any other error, a `LinkError` or the `CancellationError` of a cancelled task, ends the run: `progress`
    /// reports `.failed` for the module it came on, the error is thrown, and neither the file nor the sets are
    /// written; so does a cancel that comes in the last read of the run, though no module is then reported
    /// `.failed`. At the end the backup is written, dated when the run ended, and then the identifiers that
    /// answered are remembered for every module that was swept in full and is `complete`. The sets are only a
    /// cache: if they cannot be saved the run still succeeds, and the next one sweeps those modules in full again.
    public static func run(
        diag: Diag, modules: [DiscoveredModule], vin: String, nickname: String, adapter: AdapterInfo,
        appVersion: String, store: BackupStore, setsURL: URL, fullRescan: Bool,
        progress: @escaping (BackupProgress) -> Void
    ) async throws -> URL {
        var sets = RememberedSets.load(from: setsURL)
        var current = BackupProgress(
            moduleIndex: 0, moduleCount: modules.count, didsDone: 0, didsTotal: 0, currentAddress: 0,
            states: modules.reduce(into: [:]) { $0[$1.address] = .waiting })
        var entries: [ModuleBackup] = []
        for (index, module) in modules.enumerated() {
            let remembered = fullRescan ? nil : sets.dids(address: module.address, codingFiles: module.codingFiles)
            let dids = remembered ?? Array(Coding.fullRange)
            let method: ModuleBackup.Method = remembered == nil ? .fullSweep : .rememberedSet
            current.moduleIndex = index
            current.currentAddress = module.address
            current.didsDone = 0
            current.didsTotal = dids.count
            current.states[module.address] = .reading
            progress(current)
            let found: [UInt16: [UInt8]]
            var status = ModuleBackup.Status.complete
            do {
                found = try await Coding.read(diag: diag, module: module.address, dids: dids) { done, _ in
                    current.didsDone = done
                    progress(current)
                }
                // A file must say when a module gave nothing, or less than was remembered for it.
                if found.isEmpty {
                    status = .partial(reason: "no coding identifiers answered")
                } else if let remembered, found.count < remembered.count {
                    let missing = remembered.count - found.count
                    status = .partial(reason: "\(missing) of \(remembered.count) remembered identifiers did not answer")
                }
            } catch CodingError.moduleStoppedAnswering(after: let asked, found: let answered) {
                found = answered
                status = .partial(reason: "module stopped answering after \(asked) identifiers")
            } catch {
                current.states[module.address] = .failed(String(describing: error))
                progress(current)
                throw error
            }
            let bytes = found.values.reduce(0) { $0 + $1.count }
            current.states[module.address] = .done(identifiers: found.count, bytes: bytes)
            progress(current)
            if method == .fullSweep, status == .complete {
                sets.remember(found.keys.sorted(), address: module.address, codingFiles: module.codingFiles)
            }
            entries.append(ModuleBackup(
                address: module.address, name: module.name, signed: module.signed,
                // No identifier for the part number is known yet.
                identification: .init(partNumber: nil, hardware: module.hardware, software: module.software,
                                      serial: serial(of: module)),
                codingFiles: module.codingFiles, coding: hex(found), method: method, status: status))
        }
        // A cancel that came in the last read was seen by nothing yet, and a cancelled run leaves no file.
        try Task.checkCancellation()
        let url = try store.save(Backup(
            vin: vin, nickname: nickname, date: Date(), appVersion: appVersion,
            adapter: .init(model: adapter.model, firmware: adapter.firmware), modules: entries))
        // The sets are only a cache, so a run that cannot save them still has its backup.
        // ponytail: the failure is dropped, so a sets file that never saves means a full sweep every run, unannounced.
        // Say so on the progress or in the log if that turns up.
        try? sets.save(to: setsURL)
        return url
    }

    /// The serial number the module gave (`0xF18C`) as text: its bytes as ASCII without the blanks and padding
    /// around them, or `nil` when it gave none or only padding.
    private static func serial(of module: DiscoveredModule) -> String? {
        guard let data = module.identification[serialDID] else { return nil }
        let text = String(decoding: data, as: Unicode.ASCII.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return text.isEmpty ? nil : text
    }

    /// The data as the file holds it: identifiers as four upper-case hex digits, data as upper-case hex without
    /// spaces.
    private static func hex(_ found: [UInt16: [UInt8]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: found.map {
            (String(format: "%04X", $0.key), ISOTP.hexLine($0.value).filter { $0 != " " })
        })
    }
}
