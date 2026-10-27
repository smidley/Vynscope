import CoreBluetooth
import Foundation
import Observation

/// The OBDLink CX over Bluetooth LE. Its UART service carries the same line protocol as a serial ELM327:
/// the host writes a command ending in a carriage return and the adapter notifies the reply lines and then
/// a `>` prompt. `connect` gets to that point and `send` is one such exchange. The link does not log;
/// `Diag` does.
///
/// Everything runs on the main actor. The central manager is created with `queue: nil`, so CoreBluetooth
/// calls back on the main queue, and `@preconcurrency` lets the main-actor delegate methods satisfy the
/// nonisolated protocol requirements.
@Observable
public final class BLELink: NSObject, CommandLink {
    /// `.connecting` runs from finding the adapter to the confirmed subscription. `.failed` carries what to
    /// show: why connecting failed, or that the adapter dropped.
    public enum State: Equatable { case off, scanning, connecting, ready, failed(String) }

    public private(set) var state: State = .off
    /// The adapter's Device Information strings, read while connecting; nil when it has none.
    public private(set) var deviceModel: String?
    public private(set) var deviceFirmware: String?

    private static let uartService = CBUUID(string: "FFF0")
    private static let notifyUUID = CBUUID(string: "FFF1")  // adapter to host
    private static let writeUUID = CBUUID(string: "FFF2")  // host to adapter
    private static let deviceInfoService = CBUUID(string: "180A")
    private static let modelUUID = CBUUID(string: "2A24")
    private static let firmwareUUID = CBUUID(string: "2A26")
    private static let identifierKey = "adapterIdentifier"

    /// What `connect` and `send` suspend on. Each is ended by the delegate callback that reports it.
    private enum Event {
        case power, found, connected, services, characteristics, read, subscribed, written, response
    }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var adapter: CBPeripheral?
    @ObservationIgnored private var notifyCharacteristic: CBCharacteristic?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    /// The one thing `connect` or `send` is suspended on, with the continuation that resumes it.
    @ObservationIgnored private var waiter: (event: Event, continuation: CheckedContinuation<Void, any Error>)?
    /// Notified text that has not yet been taken as a reply.
    @ObservationIgnored private var buffer = ""
    /// True while a command is in flight.
    @ObservationIgnored private var busy = false

    public override init() { super.init() }

    /// Finds the adapter (the one remembered from last time, else the first that advertises the UART
    /// service), connects, reads its model and firmware, and subscribes to its output; the subscription is
    /// what makes the system ask to pair. All of it must finish within 20 seconds. On any failure the state
    /// is `.failed` and this throws `LinkError.adapterError` with the same message. Returns at once when
    /// already connected and throws while another connect is in progress.
    public func connect() async throws {
        switch state {
        case .ready: return
        case .scanning, .connecting: throw LinkError.adapterError("Already connecting")
        case .off, .failed: break
        }
        state = .connecting
        deviceModel = nil
        deviceFirmware = nil
        do {
            try await establish(by: ContinuousClock.now + .seconds(20))
            // A disconnect that landed while the last step was waking up has already set the state.
            guard state == .connecting else { throw LinkError.disconnected }
            if let adapter { UserDefaults.standard.set(adapter.identifier.uuidString, forKey: Self.identifierKey) }
            state = .ready
        } catch {
            let message: String
            switch error {
            case LinkError.adapterError(let text): message = text
            case LinkError.disconnected: message = "Adapter disconnected"
            default: message = error.localizedDescription
            }
            tearDown(.failed(message))
            throw LinkError.adapterError(message)
        }
    }

    /// Drops the connection (or the scan) and fails whatever is waiting on the adapter, including a connect
    /// in progress, with `LinkError.disconnected`.
    public func disconnect() {
        tearDown(.off)
    }

    /// Writes `command` and returns the reply lines up to the `>` prompt, trimmed, without blank lines or
    /// an echo of the command. One command is in flight at a time: a second call waits for the first. The
    /// timeout covers the writes and the reply. Throws `LinkError.timeout` if the prompt does not arrive in
    /// time, `.disconnected` if the link is not up or drops, and `.adapterError` if CoreBluetooth reports a
    /// failed write or notification.
    public func send(_ command: String, timeout: Duration) async throws -> [String] {
        // ponytail: polling, not a queue; callers (Diag) are serial, so this loop does not run in practice.
        // Replace with an AsyncStream queue if callers ever overlap.
        while busy { try await Task.sleep(for: .milliseconds(20)) }
        guard state == .ready, let adapter, let writeCharacteristic else { throw LinkError.disconnected }
        guard let bytes = (command + "\r").data(using: .ascii) else {
            throw LinkError.adapterError("Not an ASCII command: \(command)")
        }
        busy = true
        defer { busy = false }
        buffer = ""  // anything here is left over from an earlier command, or unprompted
        let deadline = ContinuousClock.now + timeout
        do {
            let size = max(1, adapter.maximumWriteValueLength(for: .withResponse))
            for start in stride(from: 0, to: bytes.count, by: size) {
                let chunk = Data(bytes[start ..< min(start + size, bytes.count)])
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

    /// Drops the scan or connection, fails whatever is waiting with `LinkError.disconnected`, and moves to
    /// `newState`.
    private func tearDown(_ newState: State) {
        if state == .scanning { central?.stopScan() }
        if let central, let adapter { central.cancelPeripheralConnection(adapter) }
        adapter = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        wake(nil, error: LinkError.disconnected)
        state = newState
    }
}

// MARK: CoreBluetooth callbacks (public only because the protocols are; not for callers)

extension BLELink: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
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
        wake(.connected)
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?
    ) {
        guard peripheral === adapter else { return }
        wake(.connected, error: error ?? LinkError.adapterError("Could not connect to the adapter"))
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?
    ) {
        guard peripheral === adapter else { return }  // not ours, or a disconnect we asked for
        tearDown(.failed("Adapter disconnected"))
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
}
