import BMWCodingCore
import Foundation
import Observation

/// The steps of the flow, in order.
enum Step: Int, CaseIterable {
    case connect, car, modules, backup

    var title: LocalizedStringResource {
        switch self {
        case .connect: "Connect"
        case .car: "Car"
        case .modules: "Modules"
        case .backup: "Backup"
        }
    }
}

/// The state of the four steps and the actions that talk to the car. The adapter takes one request at a time, so
/// every action that uses `diag` holds `busy` while it runs, and one that finds `busy` set only says so in `error`.
@Observable @MainActor
final class Flow {
    var step = Step.connect
    let link = BLELink()
    let log = Log()
    var diag: Diag?
    var adapter: AdapterInfo?
    var vin: String?
    var car: CarRecord?
    var modules: [DiscoveredModule] = []
    var discovering = false
    var progress: BackupProgress?
    var lastBackup: URL?
    var error: String?
    var busy = false
    /// The Log sheet on the iPhone; the Mac opens a window instead.
    var showingLog = false

    /// Where `BLELink` saves the identifier of the last adapter it connected to.
    static let adapterKey = "adapterIdentifier"

    init() {
        let file = logFile()
        // ponytail: one older file is kept, as log-previous.txt; anything before it is gone.
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 20_000_000 {
            let previous = appFolder().appending(path: "log-previous.txt")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: file, to: previous)
        }
        do {
            try log.attachFile(file)
        } catch {
            log.note("could not open the log file \(file.path): \(error.localizedDescription)")
        }
        log.note("session started \(Date.now.formatted(.iso8601))")
    }

    /// Whether Next (Done on the last step) may be pressed.
    var canGoNext: Bool {
        guard !busy else { return false }
        return switch step {
        case .connect: adapter != nil
        case .car: vin != nil
        case .modules: !discovering && !modules.isEmpty
        case .backup: lastBackup != nil
        }
    }

    /// The next step; Done on the last one starts over at Connect.
    func next() {
        error = nil
        step = Step(rawValue: step.rawValue + 1) ?? .connect
    }

    func back() {
        error = nil
        step = Step(rawValue: step.rawValue - 1) ?? .connect
    }

    /// Connects to the adapter (the saved one, else the first found) and sets it up. A saved adapter that does
    /// not connect is forgotten, so that the next try scans instead of waiting out the timeout again.
    func connect() async {
        guard !busy else { error = "Still working"; return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await link.connect()
        } catch {
            var message = Self.describe(error)
            if UserDefaults.standard.string(forKey: Self.adapterKey) != nil {
                UserDefaults.standard.removeObject(forKey: Self.adapterKey)
                message += "\nForgot the saved adapter; Connect scans for one next time."
            }
            self.error = message
            return
        }
        do {
            let diag = Diag(link: link, log: log)
            adapter = try await diag.setUp()
            self.diag = diag
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Drops the adapter and goes back to Connect; whatever waits on the adapter fails. The way out when the radio
    /// has dropped but the link still reports ready, so every command times out.
    func disconnect() {
        link.disconnect()
        adapter = nil
        diag = nil
        step = .connect
    }

    /// The folder for the log, the car book, the remembered sets and the backups: Documents on the iPhone, where
    /// Files shows it; on the Mac the folder chosen on the Backup step, else `~/Documents/BMW Coding`. Created if
    /// missing.
    func appFolder() -> URL {
        #if os(macOS)
        let folder = UserDefaults.standard.string(forKey: "backupFolder").map { URL(filePath: $0) }
            ?? URL.documentsDirectory.appending(path: "BMW Coding")
        #else
        let folder = URL.documentsDirectory
        #endif
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func logFile() -> URL { appFolder().appending(path: "log.txt") }

    /// What to show for an error from the adapter or the car.
    static func describe(_ error: any Error) -> String {
        switch error {
        case LinkError.adapterError(let text): text
        case LinkError.timeout: "The adapter did not answer in time"
        case LinkError.disconnected: "The adapter is not connected"
        default: error.localizedDescription
        }
    }
}
