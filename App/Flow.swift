import BMWCodingCore
import Foundation
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The app's four tabs.
enum AppTab: Hashable {
    case car, diagnostics, programming, settings
}

/// How a module's write test ended, for the module screen.
enum WriteTestResult {
    /// The check against the backup found a reason not to write; never `.ready`.
    case preparation(WriteTest.Preparation)
    case outcome(WriteTest.Outcome)
    /// Stopped by the owner or by a link error (`why`) after `done` of `total` identifiers were confirmed; `total` is 0
    /// when it stopped before there were identifiers to write, as for a module no longer listed.
    case stopped(done: Int, total: Int, why: String?)
}

/// A step of Check my car, in the order the check runs them; a step the car does not need is skipped.
enum CheckStep: Equatable {
    case connecting, readingCar, findingSystems, readingFaults
}

/// A screen pushed on the Diagnostics tab's stack: the mechanic, from Fault codes or the check's Explain it.
enum DiagnosticsRoute: Hashable {
    case mechanic
}

/// The state behind the tabs and the actions that talk to the car. The adapter takes one request at a time, so
/// every action that uses `diag` holds `busy` while it runs, and one that finds `busy` set only says so in `error`.
@Observable @MainActor
final class Flow {
    /// The tab on screen. A reconnect that failed and a different car go back to Car.
    var tab = AppTab.car
    /// Whether the screens and controls that need car knowledge are shown: Programming, the adapter's details, raw
    /// status bytes, the log and the model, effort, price and folder settings. Off until the owner turns it on; the
    /// choice is kept in the user defaults, and turning it off moves a flow on Programming to Car.
    var advanced = UserDefaults.standard.bool(forKey: Flow.advancedKey) {
        didSet {
            UserDefaults.standard.set(advanced, forKey: Flow.advancedKey)
            if !advanced && tab == .programming { tab = .car }
        }
    }
    /// The Diagnostics tab's navigation stack: empty for Fault codes, `[.mechanic]` with the mechanic pushed.
    var diagnosticsPath: [DiagnosticsRoute] = []
    let log = Log()
    let link: BLELink
    var diag: Diag?
    var adapter: AdapterInfo?
    var vin: String?
    var car: CarRecord?
    /// The other cars in the car book.
    var otherCars: [CarRecord] = []
    var modules: [DiscoveredModule] = []
    var discovering = false
    /// How far the scan is: the module address it is at, 0...255, on a walk of every address; the number of remembered
    /// systems already asked, 0..<`scanTotal`, on a quick walk. Modules and Backups draw it as progress.
    var scanned = 0
    /// Whether the scan in progress covers only the car's remembered systems; false while none runs.
    var scanQuick = false
    /// What `scanned` counts up to: 255 on a walk of every address, the number of remembered systems on a quick one.
    var scanTotal = 255
    /// What a quick walk says it is doing, at the remembered system it asks: the connection line's, the Modules and
    /// Backups progress's and the check card's words.
    var quickWalkWords: String { "Checking the car's systems · \(scanned + 1) of \(scanTotal)" }
    /// Whether `modules` came from a walk of every address that found at least one module, rather than from a quick
    /// walk of the remembered systems.
    var modulesFromFullWalk = false
    /// The remembered systems that did not answer the last walk that ended, of either kind; the check counts them as
    /// systems it could not read.
    var silentSystems = 0
    var progress: BackupProgress?
    var lastBackup: URL?
    /// The last fault read of the car, from Fault codes or the mechanic's health check.
    var faultReport: HealthCheck?
    /// When `faultReport` was read; set with it.
    var faultReadAt: Date?
    /// The remembered systems that stayed silent in the walk `faultReport` was read on, as `silentSystems` was then;
    /// set with it, so that a later walk does not change what the read missed.
    var faultSilent = 0
    /// The step Check my car is at; nil while no check runs.
    var checkStep: CheckStep?
    /// The last check's problem in plain words, from `CheckProblem`; cleared when a check starts, left nil by a stop.
    var checkProblem: String?
    /// What the fault read in progress is doing; nil while none runs.
    var readingFaults: String?
    var error: String?
    var busy = false
    /// The backup run in progress.
    var backupTask: Task<Void, Never>?
    /// The Log sheet on the iPhone; the Mac opens a window instead.
    var showingLog = false
    /// The launch-time connect ran; a second window does not run it again.
    @ObservationIgnored var autoConnectAttempted = false
    /// The car whose first scan the Modules screen started by itself; it is not started again for that car.
    @ObservationIgnored var autoScannedVIN: String?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    /// The fault read `readFaults()` runs, which `stopScan()` stops.
    @ObservationIgnored private var readTask: Task<Void, Never>?
    /// The check `checkCar()` runs, which `stopCheck()` stops.
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    /// The write test waiting for the owner's go-ahead; the module screen shows its confirmation while this is set.
    var writeTestReady: WriteTest.Ready?
    /// The identifiers written back and the number to write, while a write test runs; nil otherwise.
    var writeTestProgress: (done: Int, total: Int)?
    /// The module the write test is checking against its backup, or has ready, or writes; nil otherwise.
    var writeTestModule: DiscoveredModule?
    /// Whether the write test is reading the module to check it against the backup.
    var writeTestChecking = false
    /// How each module's write test ended in this session, by address.
    var writeTestResults: [UInt8: WriteTestResult] = [:]
    /// The write run in progress, which `stopWriteTest()` stops.
    @ObservationIgnored private var writeTestTask: Task<Void, Never>?

    /// Where `BLELink` saves the identifier of the last adapter it connected to.
    static let adapterKey = "adapterIdentifier"
    /// Where `advanced` is kept in the user defaults.
    private static let advancedKey = "advanced"
    /// The app folder chosen on the Mac.
    private static let folderKey = "backupFolder"
    #if os(macOS)
    /// The folder `useFolder(_:)` saved in the user defaults, held here too, where Settings sees a new choice at once.
    private var chosenFolder = UserDefaults.standard.string(forKey: Flow.folderKey)
    #endif

    init() {
        link = BLELink(log: log)
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

    /// Whether the link is coming back by itself after a drop; a screen waiting on the adapter says so.
    var reconnecting: Bool {
        if case .reconnecting = link.state { true } else { false }
    }

    /// Whether the link gave up on the adapter; Reconnect is the way back.
    var gaveUp: Bool {
        if case .failed = link.state { true } else { false }
    }

    /// What runs now, for the connection line: Checking the car while the check connects or reads the car, else the
    /// fault read at its step, else the scan, at the address it is at with the modules that answered so far, or on a
    /// quick walk at the remembered system it is asking, else the backup, at the module it reads, else the write test,
    /// checking its module against the backup or at the identifier it writes back; nil while none runs.
    var activity: String? {
        if checkStep == .connecting || checkStep == .readingCar { return "Checking the car" }
        if let readingFaults { return readingFaults }
        if discovering && scanQuick { return quickWalkWords }
        if discovering { return "Scanning \(String(format: "%02X", scanned)) of FF · \(modules.count) answered" }
        if backupTask != nil, let progress {
            return "Backing up · module \(progress.moduleIndex + 1) of \(progress.moduleCount)"
        }
        if let writeTestModule {
            let name = writeTestModule.description ?? writeTestModule.title
            if let (done, total) = writeTestProgress { return "Write test · identifier \(done + 1) of \(total) · \(name)" }
            if writeTestChecking { return "Write test · checking \(name)" }
        }
        return nil
    }

    /// Connects to the adapter (the saved one, else the first found), sets it up and reads the car with `readVIN`. A
    /// link that was not up, or one whose adapter `explain` dropped, may reach another car, so the car read before is
    /// forgotten; one that stayed up keeps it only when the car gives the same VIN, and a different car takes its
    /// place. A read that fails forgets the car and says why, leaving the adapter set up for Read unless the link
    /// itself failed (`explain`). A saved adapter that does not connect is forgotten too, so that the next try scans
    /// instead of waiting out the timeout again. Does nothing while the link reconnects by itself, which keeps the car.
    func connect() async {
        guard !reconnecting else { return }
        guard !busy else { error = "Still working"; return }
        busy = true
        defer { busy = false }
        error = nil
        let hadSaved = UserDefaults.standard.string(forKey: Self.adapterKey) != nil
        let diag: Diag
        do {
            diag = try await reachAdapter()
        } catch {
            var message = explain(error)
            if hadSaved, UserDefaults.standard.string(forKey: Self.adapterKey) == nil {
                message += "\nForgot the saved adapter; Connect scans for one next time."
            }
            self.error = message
            return
        }
        do {
            try await readVIN(diag: diag)
        } catch {
            self.error = explain(error)
        }
    }

    /// Connects to the adapter and sets it up, for `connect()` and the check: forgets the car first unless the link
    /// is up with its adapter set up, and forgets the saved adapter when the link does not connect, except in a task
    /// that was cancelled, as a stopped check, where the failure is the stop's. Leaves `busy` to the caller.
    private func reachAdapter() async throws -> Diag {
        if link.state != .ready || diag == nil {
            adapter = nil
            diag = nil
            forgetCar()
        }
        do {
            try await link.connect()
        } catch {
            if !Task.isCancelled { UserDefaults.standard.removeObject(forKey: Self.adapterKey) }
            throw error
        }
        let diag = Diag(link: link, log: log)
        do {
            adapter = try await diag.setUp()
            self.diag = diag
            return diag
        } catch {
            // The adapter is in no known setup, so nothing may use it until a setup succeeds.
            adapter = nil
            self.diag = nil
            throw error
        }
    }

    /// After a give-up: connects to the adapter again and, when the same car answers, leaves the owner where they are
    /// with the car still known; a different car, or none, forgets it and goes back to Car.
    func reconnect() async {
        guard !reconnecting else { return }  // as in `connect()`
        guard !busy else { error = "Still working"; return }
        busy = true
        defer { busy = false }
        error = nil
        // Nothing may use the adapter until a setup succeeds; meanwhile Reconnect stays in view, disabled.
        adapter = nil
        diag = nil
        do {
            try await link.connect()  // returns at once when the link is up and only the adapter's setup was lost
            let diag = Diag(link: link, log: log)
            adapter = try await diag.setUp()
            self.diag = diag
            if let known = vin {  // nil when no car was read, with no car to check
                let read = try await VIN.read(diag: diag)
                guard read == known else { throw DiagError.differentCar(read) }
                diag.expectedVIN = known
            }
        } catch {
            forgetCar()
            tab = .car
            self.error = explain(error)
        }
    }

    /// Drops the adapter, or stops a connect in progress, and forgets the car; whatever waits on the adapter fails.
    /// The way out when the radio has dropped but the link still reports ready, so every command times out.
    func disconnect() {
        link.disconnect()
        adapter = nil
        diag = nil
        forgetCar()
    }

    /// Forgets the car read through the adapter and everything found on it, its fault read and what its last walk
    /// covered included, so that nothing of one car is backed up under another's VIN or shown as another's codes.
    private func forgetCar() {
        diag?.expectedVIN = nil
        vin = nil
        car = nil
        otherCars = []
        modules = []
        modulesFromFullWalk = false
        silentSystems = 0
        progress = nil
        lastBackup = nil
        faultReport = nil
        faultReadAt = nil
        faultSilent = 0
        writeTestReady = nil
        writeTestResults = [:]
    }

    /// Read on the Car tab: stops a scan `discover()` started, then reads the car with `readVIN`. A scan run inside
    /// another action, as a fault read's, is not stopped: the action holds `busy`, and Read answers `Still working`.
    func readCar() async {
        await endDiscovery()
        guard let diag else { error = "Not connected"; return }
        guard !busy else { error = "Still working"; return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await readVIN(diag: diag)
        } catch {
            self.error = explain(error)
        }
    }

    /// Reads the VIN and looks the car up in the car book. A different car from last time, or a failed read,
    /// forgets the car read before and what was found on it; a failed read throws, for the caller to say why.
    private func readVIN(diag: Diag) async throws {
        do {
            let vin = try await VIN.read(diag: diag)
            if vin != self.vin { forgetCar() }
            self.vin = vin
            diag.expectedVIN = vin
            let book = CarBook.load(from: file("cars.json"))
            car = book.car(for: vin)
            otherCars = book.cars.filter { $0.vin != vin }
        } catch {
            forgetCar()
            throw error
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

    /// Scans for modules with `scan`, holding `busy`, in a task `stopScan()` and `endDiscovery()` can stop. With `full`
    /// the walk covers every address, as the Modules screen asks; without it only the systems remembered for the car,
    /// while its last walk of every address is recent. A stop says nothing; any other failure says why in `error`.
    /// Returns whether a stop ended it.
    @discardableResult
    func discover(full: Bool = false) async -> Bool {
        guard let diag, let vin else { error = "Not connected"; return false }
        guard !busy else { error = "Still working"; return false }
        busy = true
        error = nil
        let task = Task {
            defer { busy = false }
            do {
                try await keepingAwake("Scanning the car") { try await scan(diag: diag, vin: vin, full: full) }
            } catch is CancellationError {
                // Stopped: the list is empty, and there is nothing to say.
            } catch {
                self.error = explain(error)
            }
        }
        discoveryTask = task
        await task.value
        return task.isCancelled
    }

    /// Lists the modules that answer, as they answer, with `discovering`, `scanned` and `scanTotal` following the
    /// walk; leaves `busy` to the caller. The walk is quick, asking only the car's remembered systems
    /// (`KnownModules`), when not `full`, some are remembered and the car's last walk of every address is at most
    /// `KnownModules.maxAge` old; any other walk probes every address, so a system a first walk missed is found within
    /// a month. A walk of either kind that ends counts in `silentSystems` the remembered systems that did not answer,
    /// which the check counts as unread. A walk of every address that ends with at least one module sets
    /// `modulesFromFullWalk` and adds the answering addresses to those remembered for the VIN with the time, a failed
    /// save only logged, as the file is a cache; any other walk that ends clears `modulesFromFullWalk` and saves
    /// nothing. A walk that is cancelled or fails empties the list, saves nothing and throws, so that no backup is
    /// ever made of part of the car.
    private func scan(diag: Diag, vin: String, full: Bool) async throws {
        let saved = KnownModules.load(from: file("known-modules.json"))
        let remembered = saved.addresses(forVIN: vin) ?? []
        let quick = !full && !remembered.isEmpty && saved.isRecent(forVIN: vin, at: .now)
        // The addresses `Discovery` walks by default unless the remembered systems are asked.
        let addresses = quick ? remembered : (UInt8.min...UInt8.max).filter { $0 != 0xF1 }
        discovering = true
        scanQuick = quick
        scanTotal = quick ? addresses.count : 255
        defer { discovering = false; scanQuick = false }
        modules = []
        scanned = 0
        do {
            // One walk per address. A cancelled walk still finishes the address in progress, and nothing tells its
            // consumer when; a walk of one address is done with `diag` once its stream ends. Each walk runs in a task
            // of its own, which a stop does not cancel, so a stop waits for that end and leaves no request in flight.
            for (index, address) in addresses.enumerated() {
                scanned = quick ? index : Int(address)
                try Task.checkCancellation()
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
            throw error
        }
        silentSystems = remembered.count { address in !modules.contains { $0.address == address } }
        modulesFromFullWalk = !quick && !modules.isEmpty
        guard modulesFromFullWalk else { return }
        // Loaded again: the walk took minutes, and the file is replaced as a whole.
        var known = KnownModules.load(from: file("known-modules.json"))
        known.remember(modules.map(\.address), forVIN: vin)
        do {
            try known.save(to: file("known-modules.json"))
        } catch {
            log.note("could not save the remembered systems: \(error.localizedDescription)")
        }
    }

    /// Stops the scan `discover()` started, if it still runs, and waits until it no longer uses `diag`. A fault read's
    /// or a backup's scan is not in `discoveryTask` and runs on.
    private func endDiscovery() async {
        discoveryTask?.cancel()
        await discoveryTask?.value
    }

    /// Reads every module's fault codes and standard OBD-II with `readFaultCodes()`; scans for modules first when none
    /// is listed, asking only the car's remembered systems while its last walk of every address is recent, and every
    /// address otherwise. Runs in a task `stopScan()` can stop, which says Cancelled and keeps the report read before.
    /// Nothing is cleared.
    func readFaults() async {
        guard let diag, let vin, !gaveUp else { error = "Not connected"; return }
        guard !busy else { error = "Still working"; return }
        busy = true
        error = nil
        let task = Task {
            defer { busy = false }
            do {
                try await keepingAwake("Reading the car's fault codes") {
                    if modules.isEmpty {
                        try await scan(diag: diag, vin: vin, full: false)
                        guard !modules.isEmpty else { error = "No module answered the scan"; return }
                    }
                    guard try await readFaultCodes() else { error = "Not connected"; return }
                }
            } catch is CancellationError {
                error = "Cancelled"
            } catch {
                self.error = explain(error)
            }
        }
        readTask = task
        await task.value
    }

    /// Reads every listed module's fault codes and standard OBD-II, as the health check reads them, with
    /// `readingFaults` following the read, and keeps the read with `storeFaults(_:)`. Leaves `busy` to the caller and
    /// ends at the next request when its task is cancelled. Returns false, reading nothing, while no car is connected.
    private func readFaultCodes() async throws -> Bool {
        guard case let (diag, car)? = connectedCar() else { return false }
        readingFaults = "Reading fault codes …"
        defer { readingFaults = nil }
        storeFaults(try await Mechanic(diag: diag, car: car, log: log).healthCheck { readingFaults = $0 })
        return true
    }

    /// Keeps `report` as the car's last fault read, with the time and the remembered systems silent in the walk it
    /// was read on: Fault codes', the check's and the mechanic's health check's. Clears the last check's problem line,
    /// which the newer read answers; a check whose read nothing answered sets it again after this.
    func storeFaults(_ report: HealthCheck) {
        checkProblem = nil
        faultReport = report
        faultReadAt = .now
        faultSilent = silentSystems
    }

    /// Check my car: connects when there is no usable adapter, reads the car when no VIN is known, looks for its
    /// systems when none is listed or some remembered ones were silent in the last walk, a quick walk of the remembered
    /// systems while the car's last walk of every address is at most 30 days old and a walk of every address otherwise,
    /// then reads the fault codes, with `checkStep` at the step it runs. Holds `busy` throughout, in a task
    /// `stopCheck()` can stop. The VIN read runs in a task of its own, which the stop does not cancel; the walk and the
    /// fault read end at their next request. A stop says nothing. A step that fails, or a car that does not answer,
    /// says so in `checkProblem`; the error still goes through `explain(_:)` for its effects, its text to the log, and
    /// `error` stays nil. An error that ends a stopped check goes through `explain(_:)` too, and only its problem line
    /// is left out. Does nothing while the link reconnects by itself, as `connect()`.
    func checkCar() async {
        guard !reconnecting else { return }
        guard !busy else { error = "Still working"; return }
        busy = true
        error = nil
        checkProblem = nil
        let task = Task {
            defer { busy = false; checkStep = nil }
            await keepingAwake("Checking the car") { await runCheck() }
        }
        checkTask = task
        await task.value
    }

    /// The check's steps in order; see `checkCar()`.
    private func runCheck() async {
        var step = CheckStep.connecting
        do {
            if diag == nil || gaveUp || (link.state != .ready && !reconnecting) {
                checkStep = step
                _ = try await reachAdapter()
            }
            try Task.checkCancellation()
            guard let diag else { throw LinkError.disconnected }
            if vin == nil {
                step = .readingCar
                checkStep = step
                try await Task { try await readVIN(diag: diag) }.value
                try Task.checkCancellation()
            }
            guard let vin else { throw VINError.noVIN }
            if modules.isEmpty || silentSystems > 0 {
                step = .findingSystems
                checkStep = step
                try await scan(diag: diag, vin: vin, full: false)
                guard !modules.isEmpty else {
                    try Task.checkCancellation()  // a stop after the walk's last request says nothing
                    checkProblem = CheckProblem.silentCar
                    return
                }
            }
            try Task.checkCancellation()
            step = .readingFaults
            checkStep = step
            guard try await readFaultCodes() else { throw LinkError.disconnected }
            if faultReport?.nothingAnswered == true {
                try Task.checkCancellation()  // a stop after the read's last request says nothing
                checkProblem = CheckProblem.silentCar
            }
        } catch {
            // Its effects on the adapter and the car happen even when a stop ended the check.
            let text = explain(error)
            self.error = nil
            guard !Task.isCancelled else { return }  // stopped: the card goes back to how it was
            checkProblem = CheckProblem.line(for: error, connecting: step == .connecting)
            log.note(text)
        }
    }

    /// Stops the check in progress: while it connects by dropping the adapter, as Disconnect does, later after the
    /// request in flight.
    func stopCheck() {
        if checkStep == .connecting { disconnect() }
        checkTask?.cancel()
    }

    /// Checks the module at `address`, as `modules` lists it, against the car's newest complete backup of it with
    /// `WriteTest.prepare`, which writes nothing, holding `busy` while it reads. When everything agrees
    /// `writeTestReady` is set, which shows the confirmation; otherwise the result says why not, in
    /// `writeTestResults`, as it does when the module is no longer listed.
    func prepareWriteTest(_ address: UInt8) async {
        guard let diag, let vin, !gaveUp else { error = "Not connected"; return }
        guard !busy else { error = "Still working"; return }
        guard let module = modules.first(where: { $0.address == address }) else {
            writeTestResults[address] = .stopped(done: 0, total: 0, why: "The module is no longer listed")
            return
        }
        busy = true
        defer { busy = false }
        error = nil
        writeTestResults[module.address] = nil
        writeTestModule = module
        writeTestChecking = true
        defer { writeTestChecking = false }
        do {
            let reference = newestBackup(complete: module.address)
            switch try await WriteTest.prepare(diag: diag, module: module, vin: vin, reference: reference) {
            case .ready(let ready): writeTestReady = ready
            case let other: writeTestResults[module.address] = .preparation(other)
            }
        } catch {
            self.error = explain(error)
        }
        if writeTestReady == nil { writeTestModule = nil }
    }

    /// Writes the module's coding back with `WriteTest.run`, for `ready` as the confirmation holds it, holding `busy`,
    /// in a task `stopWriteTest()` can stop, with `writeTestProgress` following it. The result is kept in
    /// `writeTestResults`: how the run ended, or a stop after the last identifier confirmed, or a link error's text.
    /// None is kept when the car was forgotten during the run, so no other car's module shows it.
    func confirmWriteTest(_ ready: WriteTest.Ready) async {
        guard let diag, let vin, !gaveUp else { error = "Not connected"; return }
        guard !busy else { error = "Still working"; return }
        guard let module = modules.first(where: { $0.address == ready.address }) else {
            writeTestReady = nil
            writeTestModule = nil
            writeTestResults[ready.address] = .stopped(
                done: 0, total: ready.identifiers.count, why: "The module is no longer listed")
            return
        }
        busy = true
        writeTestModule = module
        error = nil
        writeTestReady = nil
        writeTestProgress = (0, ready.identifiers.count)
        let task = Task {
            defer { busy = false; writeTestProgress = nil; writeTestModule = nil }
            let result: WriteTestResult
            do {
                let outcome = try await keepingAwake("Writing back a module's coding") {
                    try await WriteTest.run(diag: diag, module: module, vin: vin, ready: ready) {
                        self.writeTestProgress = ($0, $1)
                    }
                }
                result = .outcome(outcome)
            } catch is CancellationError {
                result = .stopped(done: writeTestProgress?.done ?? 0, total: ready.identifiers.count, why: nil)
            } catch {
                let done = writeTestProgress?.done ?? 0
                let why = explain(error)  // first: it forgets the car when another one answered, which the check sees
                result = .stopped(done: done, total: ready.identifiers.count, why: why)
            }
            guard self.vin == vin else { return }  // the car was forgotten, and its results with it
            writeTestResults[module.address] = result
        }
        writeTestTask = task
        await task.value
    }

    /// Drops the prepared write test: Cancel on the confirmation.
    func cancelWriteTest() {
        guard writeTestProgress == nil else { return }  // Confirm dismisses the dialog too, after it started the run
        writeTestReady = nil
        writeTestModule = nil
    }

    /// Stops the write run in progress; it ends after the identifier it is on.
    func stopWriteTest() { writeTestTask?.cancel() }

    /// Stops the scan, the fault read or the check in progress; a backup has its own Cancel.
    func stopScan() { discoveryTask?.cancel(); readTask?.cancel(); stopCheck() }

    /// The `Diag` to the connected car and the car as the mechanic sees it; nil when no car is connected with its VIN
    /// read, as after a give-up.
    func connectedCar() -> (diag: Diag, car: MechanicCar)? {
        guard let diag, let vin, let adapter, !gaveUp else { return nil }
        let car = MechanicCar(
            vin: vin, nickname: self.car?.nickname ?? "", adapter: adapter, modules: modules,
            latestBackup: latestBackup())
        return (diag, car)
    }

    /// Starts a backup of every listed module into one file in the Backups folder, scanning for the modules first with
    /// `scan` when none is listed, or when the list came from a quick walk of the remembered systems, which would leave
    /// modules out of the backup: the scan then covers every address. A scan that finds none writes no file. Refused
    /// while a scan runs, which is left to finish. `progress` follows the run, `lastBackup` is the file once it is
    /// written, and an error or a cancel, in either stage, ends up in `error`. A full rescan sweeps every module in
    /// full even where a set of identifiers is remembered.
    func backup(fullRescan: Bool) {
        guard backupTask == nil else { error = "Still working"; return }
        backupTask = Task {
            defer { backupTask = nil }
            guard !discovering else { error = "Scanning; try again when it is done"; return }
            guard let diag, let vin, let adapter else { error = "Not connected"; return }
            guard !busy else { error = "Still working"; return }
            busy = true
            defer { busy = false }
            error = nil
            progress = nil
            lastBackup = nil
            // A first sweep takes an hour; sleep would drop the adapter. The Mac stays awake, the iPhone's screen on.
            await keepingAwake("Backing up the car") {
                do {
                    if modules.isEmpty || !modulesFromFullWalk { try await scan(diag: diag, vin: vin, full: true) }
                    guard !modules.isEmpty else { error = "No module answered the scan"; return }
                    lastBackup = try await BackupRunner.run(
                        diag: diag, modules: modules, vin: vin, nickname: car?.nickname ?? "", adapter: adapter,
                        appVersion: Self.appVersion, store: BackupStore(directory: file("Backups")),
                        setsURL: file("remembered-dids.json"), fullRescan: fullRescan
                    ) { self.progress = $0 }
                } catch is CancellationError {
                    progress = nil  // the module being read was stopped, not failed
                    error = "Cancelled"
                } catch {
                    self.error = explain(error)
                }
            }
        }
    }

    /// Runs `body` with the device kept awake: a first scan or a fault read takes minutes, and sleep would drop the
    /// adapter.
    func keepingAwake<T>(_ reason: String, _ body: () async throws -> T) async rethrows -> T {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason)
        defer { ProcessInfo.processInfo.endActivity(activity) }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        return try await body()
    }

    func cancelBackup() {
        backupTask?.cancel()
    }

    /// The newest backup file of the car whose VIN was read, or nil when there is none.
    func latestBackup() -> Backup? {
        guard let vin else { return nil }
        return try? BackupStore(directory: file("Backups")).latest(forVIN: vin)
    }

    /// The newest backup of the car whose VIN was read in which the module at `address` is complete, or nil when there
    /// is none: the write test's reference.
    func newestBackup(complete address: UInt8) -> Backup? {
        guard let vin else { return nil }
        return try? BackupStore(directory: file("Backups")).newest(forVIN: vin, complete: address)
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
        chosenFolder = folder.path
    }

    /// Asks for a folder in the open panel and makes it the app folder with `useFolder(_:)`.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { useFolder(url) }
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
            self.error = explain(error)
        }
    }
    #endif

    /// The folder for the log, the car book, the remembered sets and the backups: Documents on the iPhone, where
    /// Files shows it; on the Mac the folder chosen in Settings or on Backups, else `~/Documents/Vynscope`. Created if
    /// missing.
    func appFolder() -> URL {
        #if os(macOS)
        let folder = chosenFolder.map { URL(filePath: $0) } ?? URL.documentsDirectory.appending(path: "Vynscope")
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

    /// What to show for `error`, which ended an action: after a give-up the link's own message, which asks for
    /// Reconnect, otherwise `describe`'s. The flow follows suit and says why in `error` too, so that the Mechanic
    /// screen, which hides its own error line without a `Diag`, shows it as well. An adapter the link gave up on, that
    /// kept dropping, or whose car stayed silent after a drop is dropped with its `Diag` until Reconnect sets it up and
    /// checks the car again; the car is kept. A different car is forgotten and the owner goes back to Car.
    func explain(_ error: any Error) -> String {
        var text = Self.describe(error)
        if case LinkError.disconnected = error, case .failed(let message) = link.state { text = message }
        switch error {
        case LinkError.disconnected, DiagError.keptDropping, DiagError.carSilent:
            adapter = nil
            diag = nil
        case DiagError.differentCar:
            forgetCar()
            tab = .car
        default:
            return text
        }
        self.error = text
        return text
    }

    /// What to show for an error from the adapter or the car.
    static func describe(_ error: any Error) -> String {
        switch error {
        case LinkError.adapterError(let text): text
        case LinkError.timeout: "The adapter did not answer in time"
        case LinkError.disconnected: "The adapter is not connected"
        case LinkError.reconnected: "The adapter reconnected; try again"
        case DiagError.differentCar: "A different car answered after the reconnect"
        case DiagError.carSilent: "The car did not answer after the adapter reconnected. Is the ignition on?"
        case DiagError.keptDropping: "The adapter kept dropping. Reconnect when it is in range."
        case DiagError.notAllowed: "Not sent: only the standard OBD reads, modes 01, 03, 07 and 09, go to every module"
        case VINError.noVIN: "No module answered with a VIN. Is the ignition on?"
        default: error.localizedDescription
        }
    }
}
