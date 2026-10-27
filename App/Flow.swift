import BMWCodingCore
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

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
    /// The other cars in the car book.
    var otherCars: [CarRecord] = []
    var modules: [DiscoveredModule] = []
    var discovering = false
    var progress: BackupProgress?
    var lastBackup: URL?
    var error: String?
    var busy = false
    /// The backup run in progress.
    var backupTask: Task<Void, Never>?
    /// The Log sheet on the iPhone; the Mac opens a window instead.
    var showingLog = false
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?

    /// Where `BLELink` saves the identifier of the last adapter it connected to.
    static let adapterKey = "adapterIdentifier"
    /// The app folder chosen on the Mac.
    private static let folderKey = "backupFolder"

    init() {
        let current = logFile()
        // ponytail: one older file is kept, as log-previous.txt; anything before it is gone.
        if let size = try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 20_000_000 {
            let previous = file("log-previous.txt")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: current, to: previous)
        }
        do {
            try log.attachFile(current)
        } catch {
            log.note("could not open the log file \(current.path): \(error.localizedDescription)")
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

    /// The previous step. Leaving Modules stops a scan in progress.
    func back() {
        if step == .modules { discoveryTask?.cancel() }
        error = nil
        step = Step(rawValue: step.rawValue - 1) ?? .connect
    }

    /// Connects to the adapter (the saved one, else the first found) and sets it up. A link that was not up may
    /// reach another car, so the car read before is forgotten. A saved adapter that does not connect is forgotten
    /// too, so that the next try scans instead of waiting out the timeout again.
    func connect() async {
        guard !busy else { error = "Still working"; return }
        busy = true
        defer { busy = false }
        error = nil
        if link.state != .ready {
            adapter = nil
            diag = nil
            forgetCar()
        }
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
            // The adapter is in no known setup, so nothing may use it until a setup succeeds.
            adapter = nil
            self.diag = nil
            self.error = Self.describe(error)
        }
    }

    /// Drops the adapter, or stops a connect in progress, forgets the car and goes back to Connect; whatever waits
    /// on the adapter fails. The way out when the radio has dropped but the link still reports ready, so every
    /// command times out.
    func disconnect() {
        link.disconnect()
        adapter = nil
        diag = nil
        forgetCar()
        step = .connect
    }

    /// Forgets the car read through the adapter and everything found on it, so that nothing of one car is backed
    /// up under another's VIN.
    private func forgetCar() {
        vin = nil
        car = nil
        otherCars = []
        modules = []
        progress = nil
        lastBackup = nil
    }

    /// Reads the VIN and looks the car up in the car book. A different car from last time, or a failed read,
    /// forgets the car read before and what was found on it.
    func readCar() async {
        await endDiscovery()
        guard let diag else { error = "Not connected"; return }
        guard !busy else { error = "Still working"; return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            let vin = try await VIN.read(diag: diag)
            if vin != self.vin { forgetCar() }
            self.vin = vin
            let book = CarBook.load(from: file("cars.json"))
            car = book.car(for: vin)
            otherCars = book.cars.filter { $0.vin != vin }
        } catch {
            forgetCar()
            self.error = Self.describe(error)
        }
    }

    /// Gives the car whose VIN was read a nickname, kept in the car book.
    func name(_ nickname: String) {
        guard let vin else { return }
        var book = CarBook.load(from: file("cars.json"))
        book.set(nickname: nickname, for: vin)
        car = book.car(for: vin)
        do {
            try book.save(to: file("cars.json"))
        } catch {
            self.error = "Could not save the nickname: \(error.localizedDescription)"
        }
    }

    /// Probes every address and lists the modules that answer, as they answer. A scan that is stopped or fails
    /// leaves the list empty, so that Next never offers a backup of part of the car.
    func discover() async {
        guard let diag, let vin else { error = "Not connected"; return }
        guard !busy else { error = "Still working"; return }
        busy = true
        discovering = true
        error = nil
        modules = []
        let task = Task {
            defer {
                busy = false
                discovering = false
            }
            do {
                // The addresses `Discovery` walks by default, one walk per address. A cancelled walk still finishes
                // the address in progress, and nothing tells its consumer when; a walk of one address is done with
                // `diag` once its stream ends. Each walk runs in a task of its own, which a stop does not cancel, so
                // a stop waits for that end and leaves no request in flight.
                for address in UInt8.min...UInt8.max where address != 0xF1 {
                    if Task.isCancelled {
                        modules = []
                        return
                    }
                    modules += try await Task {
                        var found: [DiscoveredModule] = []
                        for try await module in Discovery.modules(diag: diag, vin: vin, addresses: [address]) {
                            found.append(module)
                        }
                        return found
                    }.value
                }
            } catch {
                modules = []
                self.error = Self.describe(error)
            }
        }
        discoveryTask = task
        await task.value
    }

    /// Stops a scan in progress and waits until it no longer uses `diag`.
    private func endDiscovery() async {
        discoveryTask?.cancel()
        await discoveryTask?.value
    }

    /// Starts a backup of every listed module into one file in the Backups folder. `progress` follows the run,
    /// `lastBackup` is the file once it is written, and an error or a cancel ends up in `error`. A full rescan
    /// sweeps every module in full even where a set of identifiers is remembered.
    func backup(fullRescan: Bool) {
        guard backupTask == nil else { error = "Still working"; return }
        backupTask = Task {
            defer { backupTask = nil }
            await endDiscovery()
            guard let diag, let vin, let adapter else { error = "Not connected"; return }
            guard !busy else { error = "Still working"; return }
            busy = true
            defer { busy = false }
            error = nil
            progress = nil
            lastBackup = nil
            // A first sweep takes an hour; sleep would drop the adapter. The Mac stays awake, the iPhone's screen on.
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Backing up the car")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            #endif
            do {
                lastBackup = try await BackupRunner.run(
                    diag: diag, modules: modules, vin: vin, nickname: car?.nickname ?? "", adapter: adapter,
                    appVersion: Self.appVersion, store: BackupStore(directory: file("Backups")),
                    setsURL: file("remembered-dids.json"), fullRescan: fullRescan
                ) { self.progress = $0 }
            } catch is CancellationError {
                progress = nil  // the module being read was stopped, not failed
                error = "Cancelled"
            } catch {
                self.error = Self.describe(error)
            }
        }
    }

    func cancelBackup() {
        backupTask?.cancel()
    }

    /// The newest backup file of the car whose VIN was read, or nil when there is none.
    func latestBackup() -> Backup? {
        guard let vin else { return nil }
        return try? BackupStore(directory: file("Backups")).latest(forVIN: vin)
    }

    /// Whether a backup now sweeps every listed module in full, which takes about an hour: none of them has a set
    /// of identifiers remembered from an earlier backup.
    func isFirstBackup() -> Bool {
        let sets = RememberedSets.load(from: file("remembered-dids.json"))
        return modules.allSatisfy { sets.dids(address: $0.address, codingFiles: $0.codingFiles) == nil }
    }

    #if os(macOS)
    /// Makes `folder` the app folder: backups, the car book and the remembered sets go there from now on, and the
    /// log from the next launch.
    func useFolder(_ folder: URL) {
        UserDefaults.standard.set(folder.path, forKey: Self.folderKey)
    }
    #endif

    #if DEBUG
    /// For the in-car survey: reads every identification identifier, `0xF100` to `0xF1FF`, from the module at
    /// `address` and logs each positive answer as a note `survey F1xx: <bytes>`. Debug builds only.
    func survey(_ address: UInt8) async {
        guard let diag else { error = "Not connected"; return }
        guard !busy else { error = "Still working"; return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await diag.select(module: address)
            for did in UInt16(0xF100)...0xF1FF {
                if case .positive(let data) = try await diag.readDID(address, did) {
                    log.note("survey \(String(format: "%04X", did)): \(ISOTP.hexLine(data))")
                }
            }
        } catch {
            self.error = Self.describe(error)
        }
    }
    #endif

    /// The folder for the log, the car book, the remembered sets and the backups: Documents on the iPhone, where
    /// Files shows it; on the Mac the folder chosen on the Backup step, else `~/Documents/Vynscope`. Created if
    /// missing.
    func appFolder() -> URL {
        #if os(macOS)
        let folder = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(filePath: $0) }
            ?? URL.documentsDirectory.appending(path: "Vynscope")
        #else
        let folder = URL.documentsDirectory
        #endif
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func logFile() -> URL { file("log.txt") }

    /// A file or folder in the app folder.
    private func file(_ name: String) -> URL { appFolder().appending(path: name) }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// What to show for an error from the adapter or the car.
    static func describe(_ error: any Error) -> String {
        switch error {
        case LinkError.adapterError(let text): text
        case LinkError.timeout: "The adapter did not answer in time"
        case LinkError.disconnected: "The adapter is not connected"
        case VINError.noVIN: "No module answered with a VIN. Is the ignition on?"
        default: error.localizedDescription
        }
    }
}
