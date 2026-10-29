import CoreBluetooth
import Foundation
import Observation

/// The OBDLink CX over Bluetooth LE. Its UART service carries the same line protocol as a serial ELM327:
/// the host writes a command ending in a carriage return and the adapter notifies the reply lines and then
/// a `>` prompt. `connect` gets to that point and `send` is one such exchange.
///
/// A link that was ready comes back by itself after a drop. `LinkPolicy` makes the decisions (that the link has
/// dropped, when to give up, when to keep the adapter awake, when the signal is weak) and this class carries them
/// out against CoreBluetooth. It logs only those decisions; the conversation with the car is `Diag`'s to log.
///
/// Everything runs on the main actor. The central manager is created with `queue: nil`, so CoreBluetooth
/// calls back on the main queue, and `@preconcurrency` lets the main-actor delegate methods satisfy the
/// nonisolated protocol requirements.
@Observable
public final class BLELink: NSObject, CommandLink {
    /// `.connecting` runs from finding the adapter to the confirmed subscription, `.reconnecting` from a drop of a
    /// ready link until it is ready again or the policy gives up. `.failed` carries what to show: why connecting
    /// failed, that the adapter dropped while connecting or did not come back, or that Bluetooth went off.
    public enum State: Equatable { case off, scanning, connecting, ready, reconnecting(since: Date), failed(String) }

    public private(set) var state: State = .off
    /// The adapter's Device Information strings, read while connecting; nil when it has none.
    public private(set) var deviceModel: String?
    public private(set) var deviceFirmware: String?
    /// The policy's warning for the owner: a weak signal, or a drop the link came back from, shown until the next
    /// command is answered. Nil when all is well.
    public private(set) var warning: String?
    /// How often the link has come back by itself since the app started.
    public private(set) var reconnects = 0

    private static let uartService = CBUUID(string: "FFF0")
    private static let notifyUUID = CBUUID(string: "FFF1")  // adapter to host
    private static let writeUUID = CBUUID(string: "FFF2")  // host to adapter
    private static let deviceInfoService = CBUUID(string: "180A")
    private static let modelUUID = CBUUID(string: "2A24")
    private static let firmwareUUID = CBUUID(string: "2A26")
    private static let identifierKey = "adapterIdentifier"

    /// What a connect, a command or a reconnect's preparation suspends on. Each is ended by the delegate callback
    /// that reports it.
    private enum Event {
        case power, found, connected, services, characteristics, read, subscribed, written, response
    }

    /// Where the policy's lines go: drops, reconnects, give-ups and signal warnings.
    private let log: Log?
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var adapter: CBPeripheral?
    @ObservationIgnored private var notifyCharacteristic: CBCharacteristic?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    /// The one thing the link is suspended on, with the continuation that resumes it.
    @ObservationIgnored private var waiter: (event: Event, continuation: CheckedContinuation<Void, any Error>)?
    /// Notified text that has not yet been taken as a reply.
    @ObservationIgnored private var buffer = ""
    /// True while a command or the keep-alive is in flight.
    @ObservationIgnored private var busy = false
    /// The drop, reconnect, keep-alive, probe and signal decisions, told everything through `feed`.
    @ObservationIgnored private var policy = LinkPolicy()
    /// What a command waits behind while the link reconnects.
    private let gate = ReadyGate()
    /// When the link dropped, on the clock that the gate and a reconnect's preparation count the minute on (the
    /// policy counts it in wall-clock time from the same moment).
    @ObservationIgnored private var dropInstant = ContinuousClock.now
    /// The policy's clock, from the first ready to the tear-down.
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(log: Log? = nil) {
        self.log = log
        super.init()
    }

    /// Finds the adapter (the one remembered from last time, else the first that advertises the UART
    /// service), connects, reads its model and firmware, and subscribes to its output; the subscription is
    /// what makes the system ask to pair. All of it must finish within 20 seconds. On any failure the state
    /// is `.failed` and this throws `LinkError.adapterError` with the same message. Returns at once when
    /// already connected and throws while another connect, or a reconnect, is in progress.
    public func connect() async throws {
        switch state {
        case .ready: return
        case .scanning, .connecting, .reconnecting: throw LinkError.adapterError("Already connecting")
        case .off, .failed: break
        }
        feed(.connectStarted(.now))
        state = .connecting
        deviceModel = nil
        deviceFirmware = nil
        do {
            try await establish(by: ContinuousClock.now + .seconds(20))
            // A disconnect that landed while the last step was waking up has already set the state.
            guard state == .connecting else { throw LinkError.disconnected }
            if let adapter { UserDefaults.standard.set(adapter.identifier.uuidString, forKey: Self.identifierKey) }
            becameReady()
        } catch {
            let message: String
            switch error {
            case LinkError.adapterError(let text): message = text
            case LinkError.disconnected: message = "Adapter disconnected"
            default: message = error.localizedDescription
            }
            feed(.connectFailed(.now))
            tearDown(.failed(message))
            throw LinkError.adapterError(message)
        }
    }

    /// Drops the connection (or the scan, or a reconnect) and fails whatever is waiting on the adapter, including
    /// a connect in progress, with `LinkError.disconnected`.
    public func disconnect() {
        feed(.disconnectedByOwner(.now))
        tearDown(.off)
    }

    /// Writes `command` and returns the reply lines up to the `>` prompt, trimmed, without blank lines or
    /// an echo of the command. One command is in flight at a time: a second call waits for the first. The
    /// timeout covers the writes and the reply.
    ///
    /// The link never resends a command. One sent while the link is reconnecting, or cut by a drop before its
    /// reply arrived, waits for the link to be back and throws `LinkError.reconnected`, for the caller to restore
    /// the adapter and send it again. Throws `LinkError.timeout` if the prompt does not arrive in time although
    /// the adapter still answers, `.disconnected` if the link is not up or does not come back within the minute,
    /// and `.adapterError` if CoreBluetooth reports a failed write or notification.
    public func send(_ command: String, timeout: Duration) async throws -> [String] {
        // ponytail: polling, not a queue; callers (Diag) are serial, so this loop does not run in practice.
        // Replace with an AsyncStream queue if callers ever overlap.
        while busy { try await Task.sleep(for: .milliseconds(20)) }
        if isReconnecting { try await waitForReconnect() }
        guard state == .ready else { throw LinkError.disconnected }
        busy = true
        defer { busy = false }
        feed(.commandSent(.now))
        do {
            let lines = try await exchange(command, timeout: timeout)
            feed(.commandAnswered(.now))
            return lines
        } catch LinkError.timeout where state == .ready {
            try await probe()
        } catch where isReconnecting {
            try await waitForReconnect()  // the drop cut the command before its reply arrived
        } catch {
            // A failed write or notification ends the command too. The policy must hear so, or it would keep the
            // command in flight and send no keep-alive until another command is answered.
            feed(.commandAnswered(.now))
            throw error
        }
    }

    /// One command and its reply: the writes, then the notified text up to the prompt. `send` wraps it for a
    /// caller; the keep-alive and the probe use it as it is, so that they neither queue behind a command nor
    /// count as one.
    private func exchange(_ command: String, timeout: Duration) async throws -> [String] {
        guard let adapter, let writeCharacteristic else { throw LinkError.disconnected }
        guard let bytes = (command + "\r").data(using: .ascii) else {
            throw LinkError.adapterError("Not an ASCII command: \(command)")
        }
        // A drop between two waits finds nothing waiting to fail, so each wait first checks that the connection
        // the exchange began on is still there.
        func stillConnected() throws {
            guard self.writeCharacteristic === writeCharacteristic else { throw LinkError.disconnected }
        }
        buffer = ""  // anything here is left over from an earlier command, or unprompted
        let deadline = ContinuousClock.now + timeout
        do {
            let size = max(1, adapter.maximumWriteValueLength(for: .withResponse))
            for start in stride(from: 0, to: bytes.count, by: size) {
                let chunk = Data(bytes[start ..< min(start + size, bytes.count)])
                try stillConnected()
                try await wait(for: .written, until: deadline) {
                    adapter.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
                }
            }
            while true {
                if let prompt = buffer.firstIndex(of: ">") {
                    let lines = Self.replyLines(buffer[..<prompt], dropping: command)
                    buffer.removeSubrange(...prompt)
                    return lines
                }
                try stillConnected()
                try await wait(for: .response, until: deadline)
            }
        } catch {
            buffer = ""
            throw error
        }
    }

    /// The lines of one reply: split on line breaks, trimmed, blank lines dropped, and the adapter's echo of
    /// `command` dropped (it echoes until `ATE0` takes effect).
    static func replyLines(_ reply: some StringProtocol, dropping command: String) -> [String] {
        reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != command }
    }

    // MARK: Connecting

    /// The steps of `connect`, each bounded by `deadline`.
    private func establish(by deadline: ContinuousClock.Instant) async throws {
        // One wait; `message` is what a timeout at this point means.
        func step(_ event: Event, _ message: String, start: () -> Void = {}) async throws {
            do { try await wait(for: event, until: deadline, start: start) }
            catch LinkError.timeout { throw LinkError.adapterError(message) }
        }

        // Bluetooth must be on and allowed. The first connect creates the manager, which is what makes the
        // system ask for Bluetooth permission.
        let central = self.central ?? CBCentralManager(delegate: self, queue: nil)
        self.central = central
        while central.state != .poweredOn {
            switch central.state {
            case .poweredOff: throw LinkError.adapterError("Bluetooth is off")
            case .unauthorized: throw LinkError.adapterError("Bluetooth is not allowed for this app")
            case .unsupported: throw LinkError.adapterError("This device does not support Bluetooth LE")
            default: try await step(.power, "Timed out waiting for Bluetooth. Allow it for this app if asked.")
            }
        }

        // The adapter: the one remembered from last time, else the first that advertises the UART service.
        let remembered = UserDefaults.standard.string(forKey: Self.identifierKey).flatMap { UUID(uuidString: $0) }
        if let known = remembered.flatMap({ central.retrievePeripherals(withIdentifiers: [$0]).first }) {
            adapter = known
        } else {
            state = .scanning
            try await step(.found, "No adapter found. Is it plugged in?") {
                central.scanForPeripherals(withServices: [Self.uartService])
            }
        }
        guard let peripheral = adapter else { throw LinkError.disconnected }  // dropped while waking up
        peripheral.delegate = self
        try await step(.connected, "Timed out connecting to the adapter") { central.connect(peripheral) }
        try await prepare(peripheral, by: deadline)
    }

    /// What follows the connection, for a connect and a reconnect alike: the adapter's services and the
    /// characteristics used from them, its model and firmware, and the subscription to its output. Each step is
    /// bounded by `deadline`.
    private func prepare(_ peripheral: CBPeripheral, by deadline: ContinuousClock.Instant) async throws {
        // One wait; `message` is what a timeout at this point means. A drop or a tear-down between two steps finds
        // nothing waiting to fail, so each step first checks that the adapter is still the link's and connected.
        func step(_ event: Event, _ message: String, start: () -> Void = {}) async throws {
            guard peripheral === adapter, peripheral.state == .connected else { throw LinkError.disconnected }
            do { try await wait(for: event, until: deadline, start: start) }
            catch LinkError.timeout { throw LinkError.adapterError(message) }
        }

        // Its services and the characteristics used from them.
        try await step(.services, "Timed out discovering the adapter's services") {
            peripheral.discoverServices([Self.uartService, Self.deviceInfoService])
        }
        let services = peripheral.services ?? []
        for service in services {
            try await step(.characteristics, "Timed out discovering the adapter's characteristics") {
                peripheral.discoverCharacteristics(
                    [Self.notifyUUID, Self.writeUUID, Self.modelUUID, Self.firmwareUUID], for: service)
            }
        }
        let characteristics = services.flatMap { $0.characteristics ?? [] }
        func find(_ uuid: CBUUID) -> CBCharacteristic? { characteristics.first { $0.uuid == uuid } }
        notifyCharacteristic = find(Self.notifyUUID)
        writeCharacteristic = find(Self.writeUUID)
        guard let notify = notifyCharacteristic, writeCharacteristic != nil else {
            throw LinkError.adapterError("The device has no FFF0 serial service. Is it an OBDLink adapter?")
        }

        // Model and firmware are nice to show; one that is missing or unreadable stays nil.
        func readText(_ uuid: CBUUID) async throws -> String? {
            guard let characteristic = find(uuid) else { return nil }
            try await step(.read, "Timed out reading the adapter's identity") {
                peripheral.readValue(for: characteristic)
            }
            let text = characteristic.value.map { String(decoding: $0, as: UTF8.self) }?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return text?.isEmpty == false ? text : nil
        }
        deviceModel = try await readText(Self.modelUUID)
        deviceFirmware = try await readText(Self.firmwareUUID)

        // The adapter pushes its output, so the host must subscribe. This is also what triggers pairing.
        try await step(.subscribed, "Timed out subscribing. Pairing may be waiting for you to accept it.") {
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    /// Ready, after a connect or a reconnect: the policy told, the commands that waited out a reconnect let
    /// through (to throw `reconnected`), and the policy's clock running.
    private func becameReady() {
        state = .ready
        feed(.becameReady(.now))
        gate.open()
        startTicker()
    }

    // MARK: Staying connected

    /// Hands `event` to the policy and carries out what it decides, in order. The decisions are returned for the
    /// two callers that act on them as well: `dropped`, and `probe`, whose decisions are the timed-out command's.
    @discardableResult
    private func feed(_ event: LinkPolicy.Event) -> [LinkPolicy.Action] {
        let actions = policy.handle(event)
        for action in actions {
            switch action {
            case .startReconnect: startReconnect()
            case .giveUp(let message): tearDown(.failed(message))  // which cancels the request and fails the gate
            case .sendKeepAlive: keepAlive()
            case .sendProbe, .failTimedOut: break  // carried out by `probe`
            case .warn(let text): warning = text
            case .log(let text): log?.note("link: \(text)")
            }
        }
        if reconnects != policy.reconnects { reconnects = policy.reconnects }
        return actions
    }

    /// The adapter is gone: the system said so, or Bluetooth went off. While the link is ready or reconnecting
    /// the policy starts a reconnect, or asks for the adapter again; a drop during a connect fails it as before.
    private func dropped(_ reason: String, failure: String) {
        if !feed(.dropped(.now, reason: reason)).contains(.startReconnect) { tearDown(.failed(failure)) }
    }

    /// The policy's reconnect, after a drop. The first drop moves the link to `reconnecting` and closes the gate.
    /// Every drop fails what waits on the adapter (`send` turns that into the wait for the reconnect) and asks the
    /// system for the adapter again.
    private func startReconnect() {
        if !isReconnecting, case .reconnecting(let since) = policy.phase {
            state = .reconnecting(since: since)
            dropInstant = .now
            gate.close()
        }
        notifyCharacteristic = nil
        writeCharacteristic = nil
        wake(nil, error: LinkError.disconnected)
        requestConnection()
    }

    /// Asks the system to connect to the kept adapter. CoreBluetooth keeps the request pending until the adapter
    /// is in range, so one request is the retry loop: nothing is asked while one is pending, and nothing while
    /// Bluetooth is off (it is asked when Bluetooth is back). An adapter CoreBluetooth still holds as connected
    /// (it stopped answering the keep-alive or the probe) is let go first; its disconnect callback asks again.
    private func requestConnection() {
        guard let central, let adapter, central.state == .poweredOn else { return }
        switch adapter.state {
        case .disconnected: central.connect(adapter)
        case .connected: central.cancelPeripheralConnection(adapter)
        default: break  // a request pending, or a disconnect under way whose callback asks again
        }
    }

    /// The adapter is back after a drop: the preparation a connect does, within the minute from the drop, then
    /// ready again. A preparation that fails tells the policy nothing and leaves the link reconnecting: a drop
    /// during it has already asked for the adapter again, and anything else ends at the give-up.
    private func finishReconnect(_ peripheral: CBPeripheral) async {
        do {
            try await prepare(peripheral, by: dropInstant + LinkPolicy.window)
        } catch {
            return
        }
        // Given up, disconnected by the owner, or dropped again while the last step was waking up.
        guard isReconnecting, peripheral.state == .connected else { return }
        becameReady()
    }

    /// The policy's clock: a tick every second while the link is ready or reconnecting, and a signal reading
    /// every fifth tick while it is ready. Started by the first ready, it runs through reconnects until the
    /// tear-down cancels it.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            var ticks = 0
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                ticks += 1
                feed(.tick(.now))
                if ticks.isMultiple(of: Int(LinkPolicy.signalEvery / .seconds(1))), state == .ready {
                    adapter?.readRSSI()
                }
            }
        }
    }

    /// The policy's keep-alive, due after 30 quiet seconds: `ATI`, so that the adapter does not go to sleep and
    /// a silent drop shows within seconds. One that finds a command in flight is skipped and counted as answered,
    /// since the policy waits on an answer and a command is using the channel.
    private func keepAlive() {
        guard !busy else {
            feed(.keepAliveAnswered(.now))
            return
        }
        busy = true
        Task {
            let answered = await adapterAnswers()
            busy = false
            feed(answered ? .keepAliveAnswered(.now) : .keepAliveMissed(.now))
        }
    }

    /// A caller's command timed out on a link that says ready. CoreBluetooth reports a lost link only after its
    /// supervision timeout, so the policy has the adapter asked first: an answer means the car was silent and the
    /// command fails with `timeout`; no answer is a drop, and the command waits out the reconnect.
    private func probe() async throws -> Never {
        guard feed(.commandTimedOut(.now)).contains(.sendProbe) else { throw LinkError.timeout }
        let answered = await adapterAnswers()
        if feed(answered ? .probeAnswered(.now) : .probeMissed(.now)).contains(.failTimedOut) {
            throw LinkError.timeout
        }
        try await waitForReconnect()
    }

    /// Whether the adapter answers `ATI`, its own identify command, within 2 seconds: the keep-alive and the
    /// probe. It never reaches the car. A bare carriage return is never sent instead, as it repeats the last
    /// command, which could be a car read.
    private func adapterAnswers() async -> Bool {
        (try? await exchange("ATI", timeout: .seconds(2))) != nil
    }

    /// For a command sent while the link reconnects, or cut by the drop: waits for the link to be back and throws
    /// `LinkError.reconnected`. Throws `LinkError.disconnected` when it does not come back. The policy's give-up,
    /// on the first tick past the minute, moves the link to `failed` before it fails the gate, so the deadline
    /// here sits two ticks later as a backstop, and the waiting command sees the give-up's message.
    private func waitForReconnect() async throws -> Never {
        guard isReconnecting else { throw LinkError.disconnected }
        do { try await gate.wait(until: dropInstant + LinkPolicy.window + .seconds(2)) }
        catch LinkError.timeout { throw LinkError.disconnected }
        throw LinkError.reconnected
    }

    /// Whether the link is coming back after a drop.
    private var isReconnecting: Bool {
        switch state {
        case .reconnecting: true
        default: false
        }
    }

    // MARK: Waiting

    /// Suspends until the delegate callback for `event` calls `wake`, or throws `LinkError.timeout` at
    /// `deadline`. `start` runs once the wait is registered, so no callback can come before it.
    private func wait(
        for event: Event, until deadline: ContinuousClock.Instant, start: () -> Void = {}
    ) async throws {
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { wake(event, error: LinkError.timeout) }
        }
        defer { timer.cancel() }  // a timer that outlived its wait must not time out the next one
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waiter = (event, continuation)
            start()
        }
    }

    /// Ends the wait on `event` (any wait when nil), if that is what the link is suspended on; otherwise
    /// does nothing. A CoreBluetooth error becomes `LinkError.adapterError`. The continuation is taken out
    /// of `waiter` before it is resumed, so it is resumed at most once however often this is called.
    private func wake(_ event: Event?, error: (any Error)? = nil) {
        guard let waiting = waiter, event == nil || event == waiting.event else { return }
        waiter = nil
        if let error {
            let failure = error as? LinkError ?? LinkError.adapterError(error.localizedDescription)
            waiting.continuation.resume(throwing: failure)
        } else {
            waiting.continuation.resume()
        }
    }

    /// Drops the scan, the connection or the pending reconnect, stops the policy's clock, fails whatever is
    /// waiting (on the adapter or behind the gate) with `LinkError.disconnected`, and moves to `newState`.
    private func tearDown(_ newState: State) {
        if state == .scanning { central?.stopScan() }
        if let central, let adapter { central.cancelPeripheralConnection(adapter) }
        adapter = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        ticker?.cancel()
        ticker = nil
        wake(nil, error: LinkError.disconnected)
        gate.fail(.disconnected)
        state = newState
    }
}

// MARK: CoreBluetooth callbacks (public only because the protocols are; not for callers)

extension BLELink: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Bluetooth off ends a scan or a connection without any callback of their own, so it is ended here; a
        // connect still waiting for power checks the state itself, to say why it cannot go on. A link that was
        // ready reconnects instead, and asks for the adapter once Bluetooth is back.
        if central.state == .poweredOn {
            if isReconnecting { requestConnection() }
        } else if state == .ready || isReconnecting {
            dropped("Bluetooth is off", failure: "Bluetooth is off")
        } else if state != .off, waiter?.event != .power {
            tearDown(.failed("Bluetooth is off"))
        }
        wake(.power)
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard state == .scanning else { return }  // a scan can report again before it has stopped
        central.stopScan()
        adapter = peripheral
        state = .connecting
        wake(.found)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === adapter else { return }
        if isReconnecting {
            Task { await finishReconnect(peripheral) }
        } else {
            wake(.connected)
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?
    ) {
        guard peripheral === adapter else { return }
        // CoreBluetooth counts a failed request as transient, so a reconnect asks again within its minute.
        if isReconnecting { return requestConnection() }
        wake(.connected, error: error ?? LinkError.adapterError("Could not connect to the adapter"))
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?
    ) {
        guard peripheral === adapter else { return }  // not ours, or one torn down
        // No error means the app asked for it: `requestConnection` let go of a silent adapter to ask for it again.
        if error == nil, isReconnecting { return requestConnection() }
        let reason = error?.localizedDescription ?? "no reason given"
        dropped(reason, failure: "Adapter disconnected: \(reason)")
    }
}

extension BLELink: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        wake(.services, error: error)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?
    ) {
        wake(.characteristics, error: error)
    }

    /// Both a finished read of a Device Information string and a notification from the adapter.
    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?
    ) {
        guard characteristic.uuid == Self.notifyUUID else {
            wake(.read)  // a failed read is not an error: the string stays nil
            return
        }
        if let error {
            wake(.response, error: error)
            return
        }
        buffer += String(decoding: characteristic.value ?? Data(), as: UTF8.self)
        if buffer.contains(">") { wake(.response) }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?
    ) {
        wake(.written, error: error)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard characteristic.uuid == Self.notifyUUID else { return }
        wake(.subscribed, error: error)
    }

    /// A signal reading the policy's clock asked for; the policy warns after two weak ones in a row.
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: (any Error)?) {
        guard error == nil else { return }
        feed(.signal(Int(truncating: RSSI), .now))
    }
}
