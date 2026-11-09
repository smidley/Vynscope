/// What a module made of one UDS request.
public enum UDSResult: Equatable, Sendable {
    /// The whole response payload, starting with the response service id (the request's plus `0x40`).
    case positive([UInt8])
    /// The negative response code.
    case negative(UInt8)
    /// Nothing usable came back: silence, a message that never finished, or one too short to read.
    case noResponse
}

/// How the adapter addresses the car: BMW's way, one module at a time (`ELM.initSequence`), or standard
/// OBD-II to every controller at once (`ELM.obdSequence`).
public enum Addressing: Equatable, Sendable {
    case bmw, obd
}

/// Adapter setup, UDS requests to one module at a time and standard OBD-II requests to every controller at
/// once. The adapter is a single serial channel, so callers make one call at a time; overlapping calls would
/// mix up their replies. When the link reports a reconnect, an operation restores the adapter (its setup, the car
/// checked against `expectedVIN`, the addressing it had) and runs again from its start, `restorations` times at
/// most: its caller sees a slow call, not an error. A write is the exception: it is sent once, so a reconnect
/// during one is rethrown, and the next operation restores the adapter before it runs.
public final class Diag {
    /// How long the adapter may take over one vehicle request. The frame that completes a write gets two seconds
    /// more, for the adapter's longer listen after it.
    public var readTimeout: Duration = .milliseconds(1500)
    /// The addressing the adapter is set up for: `.bmw` after `setUp()`, `.obd` once `obd(_:)` has switched
    /// it, `.bmw` again once `select(module:)` has switched back. It changes only after every command of a
    /// switch answered `OK`; after one that failed part-way, whichever of `obd(_:)` and `select(module:)` comes
    /// next does its whole switch.
    public private(set) var addressing: Addressing = .bmw
    /// The VIN of the car the flow holds, read again by a restoration before the cut operation runs again, so the
    /// work never goes on against another car. Nil before a car is read; a restoration then checks no car.
    public var expectedVIN: String?
    /// How a restoration waits after a VIN read that failed (no module answered, or a bus error); tests replace it.
    public var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// After an ignition cycle the modules may stay silent, or the bus report errors, for some seconds, so a
    /// restoration reads the VIN up to `vinRetries` times and waits `vinRetryInterval` after each read that fails so.
    /// With a silent car that is about two minutes, since each read takes about 1.5 s before its 2 s pause.
    public static let vinRetryInterval: Duration = .seconds(2)
    public static let vinRetries = 30
    /// How many times one operation is restored and run again; a further reconnect fails it with
    /// `DiagError.keptDropping`, so a link that keeps dropping cannot loop forever.
    public static let restorations = 3
    private let link: CommandLink
    private let log: Log
    /// The module the adapter's receive filter and flow-control address are set for, when known.
    private var selected: UInt8?
    /// False from the first command of a switch between the addressings until its last one answered `OK`: the
    /// adapter may then be set up for neither, so the next `obd(_:)` or `select(module:)` does its switch again.
    private var settled = true
    /// True while a restoration sets the adapter up and reads the VIN: the operations of that read then let a
    /// reconnect through to the operation being restored, so a drop during a restoration counts and never nests.
    private var restoring = false
    /// True from the start of a restoration until its car check passed, or found no car to check: a restoration
    /// that failed part-way leaves it set, as does a write a reconnect cut, which is never run again, and the next
    /// operation restores the adapter before it runs.
    private var carUnchecked = false

    public init(link: CommandLink, log: Log) {
        self.link = link
        self.log = log
    }

    /// Resets the adapter, applies `ELM.initSequence` (BMW addressing) and reads its identity. Throws
    /// `LinkError.adapterError("<command>: <answer>")` for the first setup command that does not answer `OK`.
    public func setUp() async throws -> AdapterInfo {
        // After a reconnect the restoration's own setup is this one: the adapter is not set up twice.
        try await resilient(rawSetUp, rerun: setUpAndCheckCar)
    }

    /// The battery voltage the adapter measures at the OBD socket (`ATRV`): the first line of its answer that reads
    /// as a number followed by `V`, as `12.6V`; nil when none does.
    public func batteryVoltage() async throws -> Double? {
        let lines = try await resilient { try await send("ATRV", timeout: .seconds(2)) }
        return lines.compactMap { $0.hasSuffix("V") ? Double($0.dropLast()) : nil }.first
    }

    /// Points the adapter at `module`: it passes on only that module's frames and sends its flow control
    /// to it. Does nothing when `module` is already the selected one. After `obd(_:)`, or a switch that failed
    /// part-way, it first sets BMW addressing up again (every command must answer `OK`), which forgets the
    /// module selected before, so it is set again.
    public func select(module: UInt8) async throws {
        try await resilient { try await rawSelect(module) }
    }

    /// Sends one UDS request to `module`, which must be set up and selected, and reads its whole answer,
    /// doing the flow-control round trip by hand when the answer has several frames. Throws
    /// `LinkError.adapterError` as soon as the adapter prints an error line. Every UDS operation below but
    /// `writeDID` sends through here, so this is where they run again after a reconnect.
    func request(_ module: UInt8, _ payload: [UInt8]) async throws -> UDSResult {
        try await resilient {
            let result = try await exchange(module, payload)
            guard result == .negative(0x78) else { return result }
            // ponytail: one fixed wait and one re-ask; a module that stays pending longer reads as
            // .negative(0x78). Add a capped loop if a slow module turns up.
            log.note("module \(ISOTP.hexLine([module])) answered response pending (0x78), asking again in 500 ms")
            try await Task.sleep(for: .milliseconds(500))
            return try await exchange(module, payload)
        }
    }

    /// Reads data identifier `did` (service `0x22`). A positive carries only the data, without the
    /// service and identifier echo; a positive that does not echo `did` is `.noResponse`.
    public func readDID(_ module: UInt8, _ did: UInt16) async throws -> UDSResult {
        let hi = UInt8(did >> 8), lo = UInt8(truncatingIfNeeded: did)
        let result = try await request(module, [0x22, hi, lo])
        guard case .positive(let payload) = result else { return result }
        guard payload.starts(with: [0x62, hi, lo]) else {
            let got = ISOTP.hexLine(payload), asked = ISOTP.hexLine([hi, lo])
            return noResponse(module, "answered \(got) to a read of \(asked)")
        }
        return .positive(Array(payload.dropFirst(3)))
    }

    /// Reads the stored faults of `module` (service `0x19`, sub-function `0x02`, status mask `0xFF`: every
    /// fault, whatever its status). A positive is the whole answer, starting `59 02`. The caller selects the
    /// module first, as for `readDID`.
    public func readFaults(_ module: UInt8) async throws -> UDSResult {
        try await request(module, [0x19, 0x02, 0xFF])
    }

    /// Sends TesterPresent (`0x3E`); true when the module confirms it.
    public func testerPresent(_ module: UInt8) async throws -> Bool {
        try await request(module, [0x3E, 0x00]) == .positive([0x7E, 0x00])
    }

    /// Asks `module` for the extended diagnostic session (`0x10 0x03`); true when it agrees.
    public func enterExtendedSession(_ module: UInt8) async throws -> Bool {
        guard case .positive(let payload) = try await request(module, [0x10, 0x03]) else { return false }
        return payload.starts(with: [0x50, 0x03])
    }

    /// Writes `data` to identifier `did` of `module` (service `0x2E`), selecting the module first. A positive is the
    /// whole answer, `6E` and the identifier when the module took the write; a negative is a refusal, never the
    /// write's response pending (`7F 2E 78`). The write is sent once, by `sendOnce`: never asked again after a
    /// pending, and never run again after a reconnect, which is rethrown and leaves the adapter for the next
    /// operation to restore. Internal, so that only the write test sends one.
    func writeDID(_ module: UInt8, _ did: UInt16, _ data: [UInt8]) async throws -> UDSResult {
        try await select(module: module)
        do {
            return try await sendOnce(module, [0x2E, UInt8(did >> 8), UInt8(truncatingIfNeeded: did)] + data)
        } catch LinkError.reconnected {
            carUnchecked = true
            throw LinkError.reconnected
        }
    }

    /// Sends one standard OBD-II request to every controller at once and returns each one's complete answer by
    /// the CAN id it came on (`0x7E8...0x7EF`). The adapter must be set up; it is switched to OBD addressing
    /// first when it is not there (every command must answer `OK`), which undoes a previous `select`: a module
    /// read after this must be selected again. An id whose message did not finish, or that answered negatively,
    /// is left out and noted; `NO DATA` gives an empty dictionary. Throws `LinkError.adapterError` as soon as
    /// the adapter prints an error line. The payload is sent as given: the caller enforces the read-only
    /// allow-list.
    public func obd(_ payload: [UInt8]) async throws -> [UInt16: [UInt8]] {
        let lines = try await resilient {
            try await rawSwitchToOBD()
            return try await send(ISOTP.hexLine(payload), timeout: readTimeout)
        }
        // ponytail: no wait and re-ask on 0x78 (response pending) as in `request(_:_:)`; a controller still
        // pending is left out like any negative answer. Add the re-ask if one turns up.
        var frames: [UInt16: [[UInt8]]] = [:]  // by CAN id, in the order received
        for line in lines {
            switch ELM.parse(line) {
            case .frame(let id, let data) where (0x7E8...0x7EF).contains(id) && !data.isEmpty:
                frames[id, default: []].append([0x00] + data)  // `reassemble` expects an address byte first
            case .error(let text): throw LinkError.adapterError(text)
            case .frame, .text, .noData: break
            }
        }
        var answers: [UInt16: [UInt8]] = [:]
        for (id, group) in frames.sorted(by: { $0.key < $1.key }) {  // sorted, so the notes come in id order
            switch ISOTP.reassemble(group) {
            case .complete(let bytes) where bytes.first != 0x7F: answers[id] = bytes
            case .complete(let bytes): leftOut(id, "negative answer \(ISOTP.hexLine(bytes))")
            case .needFlowControl(let expected): leftOut(id, "only the first frame of \(expected) bytes arrived")
            case .incomplete(let received, let expected): leftOut(id, "\(received) of \(expected) bytes arrived")
            case .empty: leftOut(id, "no frame carried a message")
            }
        }
        return answers
    }

    /// Runs `operation`; when the link reports a reconnect, restores the adapter and runs it again from its start
    /// (or `rerun` in its place), `restorations` times at most, then fails with `DiagError.keptDropping`. A
    /// reconnect during a restoration ends that restoration and counts as the next one. An operation that begins
    /// after a restoration failed part-way restores first, so it never runs against a car that was not checked.
    private func resilient<T>(
        _ operation: () async throws -> T, rerun: (() async throws -> T)? = nil
    ) async throws -> T {
        let saved = (obd: addressing == .obd, module: selected)  // the addressing the operation began with
        for attempt in 0...Self.restorations {
            do {
                if attempt > 0 {
                    log.note("the link reconnected: restoring the adapter, then running the cut operation again "
                        + "(\(attempt) of \(Self.restorations))")
                } else if carUnchecked && !restoring {
                    log.note("the adapter was not restored after the last reconnect: "
                        + "restoring it before this operation")
                } else {
                    return try await operation()
                }
                if let rerun { return try await rerun() }
                try await restore(saved)
                return try await operation()
            } catch LinkError.reconnected where !restoring {}  // the next attempt restores the adapter
        }
        log.note("the link reconnected again after \(Self.restorations) restorations of one operation: giving up")
        throw DiagError.keptDropping
    }

    /// After a reconnect: the setup again, the car checked, and the addressing the operation began with put back,
    /// whatever an earlier restoration of it left.
    private func restore(_ saved: (obd: Bool, module: UInt8?)) async throws {
        _ = try await setUpAndCheckCar()
        if saved.obd {
            try await rawSwitchToOBD()
        } else if let module = saved.module {
            selected = nil  // sent again even when the VIN read left the adapter on that module
            try await rawSelect(module)
        }
    }

    /// A restoration's setup, then the car checked when one is expected: its VIN is read up to `vinRetries` times
    /// while no module answers or the bus reports an error, so the work never goes on against another car or one
    /// that was not checked. Any other error of the read ends the restoration.
    private func setUpAndCheckCar() async throws -> AdapterInfo {
        carUnchecked = true  // until the check below passes
        restoring = true
        defer { restoring = false }
        let info = try await rawSetUp()
        guard let expectedVIN else { carUnchecked = false; return info }
        for _ in 0..<Self.vinRetries {
            do {
                let vin = try await VIN.read(diag: self)
                guard vin == expectedVIN else { throw DiagError.differentCar(vin) }
                carUnchecked = false
                return info
            } catch VINError.noVIN, LinkError.adapterError {  // silent, or a bus error line while the car wakes
                try await sleep(Self.vinRetryInterval)
            }
        }
        log.note("the car did not answer with its VIN after the reconnect, \(Self.vinRetries) tries: giving up")
        throw DiagError.carSilent
    }

    /// The setup itself, for `setUp()` and for a restoration.
    private func rawSetUp() async throws -> AdapterInfo {
        selected = nil  // the reset wipes the adapter's filter
        _ = try await send("ATZ", timeout: .seconds(3))
        addressing = .bmw  // the reset dropped any OBD setup; the sequence below is BMW's
        settled = true  // and whatever a switch that failed part-way had left
        for command in ELM.initSequence { try await expectOK(command) }
        let elmVersion = try await identity("ATI")
        let firmware = try await identity("STI")
        let model = try await identity("STDI")
        return AdapterInfo(model: model, firmware: firmware, elmVersion: elmVersion)
    }

    /// The select itself, for `select(module:)` and for a restoration.
    private func rawSelect(_ module: UInt8) async throws {
        if addressing == .obd || !settled {
            settled = false
            for command in ELM.bmwSequence { try await expectOK(command) }
            addressing = .bmw
            selected = nil  // `ATAR` dropped the filter, so even the module selected before must be set again
            settled = true
        }
        guard module != selected else { return }
        selected = nil  // the adapter's state is unknown until both commands are acknowledged
        try await expectOK("ATCRA \(String(responseID(module), radix: 16, uppercase: true))")
        try await expectOK("ATFCSD \(ISOTP.hexLine([module])) 30 00 00")
        selected = module
    }

    /// The switch to standard OBD addressing that `obd(_:)` makes first, for it and for a restoration; nothing
    /// when the adapter is in it already.
    private func rawSwitchToOBD() async throws {
        guard addressing != .obd || !settled else { return }
        settled = false
        selected = nil  // `ATAR` drops the receive filter, so a module read after this must be selected again
        for command in ELM.obdSequence { try await expectOK(command) }
        addressing = .obd
        settled = true
    }

    /// One request and its whole answer, with the flow-control round trip for a multi-frame one.
    private func exchange(_ module: UInt8, _ payload: [UInt8]) async throws -> UDSResult {
        let frame = ISOTP.singleFrame(to: module, payload: payload)
        var lines = try await send(ISOTP.hexLine(frame), timeout: readTimeout)
        var message = try assemble(lines, from: module)
        if case .needFlowControl = message {
            lines += try await send(ISOTP.hexLine(ISOTP.flowControlFrame(to: module)), timeout: readTimeout)
            message = try assemble(lines, from: module)
        }
        switch message {
        case .complete(let bytes):
            return result(of: bytes, from: module)
        case .needFlowControl(let expected):
            return noResponse(module, "only the first frame of \(expected) bytes arrived, even after flow control")
        case .incomplete(let received, let expected):
            return noResponse(module, "\(received) of \(expected) bytes arrived")
        case .empty:
            return noResponse(module, "received \(lines.isEmpty ? "nothing" : lines.joined(separator: " | "))")
        }
    }

    /// One request sent once, and its final answer: a single frame, or a first frame and then, once the module's
    /// flow control clears it, every consecutive frame. The frame that completes the request goes out under the
    /// adapter's long listen (`ATST FF`, about a second after the frame and after each frame it receives), so the
    /// final answer that follows a response pending arrives in the same lines; `ATST 32` ends the long listen
    /// whatever came back, except after a reconnect, whose restoration ends it. Nothing is ever sent again.
    private func sendOnce(_ module: UInt8, _ payload: [UInt8]) async throws -> UDSResult {
        var outgoing = payload.count <= 6
            ? [ISOTP.singleFrame(to: module, payload: payload)]
            : [ISOTP.firstFrame(to: module, payload: payload)] + ISOTP.consecutiveFrames(to: module, payload: payload)
        let completing = outgoing.removeLast()
        var blockSize = 0  // the first flow control's, which holds for the whole request
        // ponytail: no delay between consecutive frames: each send waits out the adapter's 200 ms listen (`ATST 32`),
        // longer than the 127 ms a module may ask. A faster send would have to honour the separation time.
        for (index, frame) in outgoing.enumerated() {
            let lines = try await send(ISOTP.hexLine(frame), timeout: readTimeout)
            let flowControl = try frames(in: lines, from: module).compactMap(ISOTP.flowControl).first
            // After the first frame, and after the last frame of each block, the next waits for a clear to send.
            guard index == 0 || (blockSize > 0 && index % blockSize == 0) else { continue }
            // ponytail: a wait (status 1) ends the write like an overflow (2): the adapter listens only 200 ms after
            // a frame, so a later clear to send would be missed anyway. Wait for the next flow control if a module
            // ever sends a wait.
            guard let flowControl, flowControl.status == 0 else {
                let why = flowControl.map { "flow control status \($0.status)" } ?? "no flow control"
                return noResponse(module, "the write stopped after frame \(index + 1) of \(outgoing.count + 1), \(why)")
            }
            if index == 0 { blockSize = Int(flowControl.blockSize) }
        }
        // ponytail: the wait for the final answer ends a second after the module's last frame, or at the timeout; a
        // module that stays pending longer reads as no answer. Listen on without sending (the adapter's monitor mode)
        // if one turns up.
        try await expectOK("ATST FF")
        let lines: [String]
        do {
            lines = try await send(ISOTP.hexLine(completing), timeout: readTimeout + .seconds(2))
        } catch let error where (error as? LinkError) != .reconnected {
            try? await expectOK("ATST 32")
            throw error
        }
        try await expectOK("ATST 32")
        // The answer is the module's first single frame that is not a response pending.
        for frame in try frames(in: lines, from: module) {
            guard case .complete(let bytes) = ISOTP.reassemble([frame]), bytes != [0x7F, 0x2E, 0x78] else { continue }
            return result(of: bytes, from: module)
        }
        return noResponse(module, "no final answer to the write, received "
            + (lines.isEmpty ? "nothing" : lines.joined(separator: " | ")))
    }

    /// What the frames `module` sent in `lines` add up to.
    private func assemble(_ lines: [String], from module: UInt8) throws -> Reassembly {
        ISOTP.reassemble(try frames(in: lines, from: module))
    }

    /// The frames `module` sent in `lines`, address byte first. Other lines (text, other ids, NO DATA) are
    /// skipped; an adapter error line throws.
    private func frames(in lines: [String], from module: UInt8) throws -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for line in lines {
            switch ELM.parse(line) {
            case .frame(let id, let data) where id == responseID(module): frames.append(data)
            case .error(let text): throw LinkError.adapterError(text)
            case .frame, .text, .noData: break
            }
        }
        return frames
    }

    /// What a whole answer from `module` says: the positive itself, a negative's code, or no response when it is
    /// empty or a negative cut short.
    private func result(of bytes: [UInt8], from module: UInt8) -> UDSResult {
        guard let service = bytes.first else { return noResponse(module, "empty answer") }
        guard service == 0x7F else { return .positive(bytes) }
        return bytes.count >= 3
            ? .negative(bytes[2])
            : noResponse(module, "negative answer cut short: \(ISOTP.hexLine(bytes))")
    }

    /// The CAN id `module` answers on.
    private func responseID(_ module: UInt8) -> UInt16 { 0x600 + UInt16(module) }

    /// An adapter command that must answer `OK`.
    private func expectOK(_ command: String) async throws {
        let lines = try await send(command, timeout: .seconds(2))
        guard lines.contains("OK") else {
            throw LinkError.adapterError("\(command): \(lines.joined(separator: " "))")
        }
    }

    /// The first text line the adapter answers to an identification command, or "" if it gives none
    /// (a non-STN adapter says `?` to `STI`).
    private func identity(_ command: String) async throws -> String {
        for line in try await send(command, timeout: .seconds(2)) {
            if case .text(let text) = ELM.parse(line) { return text }
        }
        return ""
    }

    /// One command to the link, logged on the way out and every line of the answer on the way in.
    private func send(_ command: String, timeout: Duration) async throws -> [String] {
        log.sent(command)
        let lines = try await link.send(command, timeout: timeout)
        for line in lines { log.received(line) }
        return lines
    }

    /// Logs why a module's answer could not be used and returns `.noResponse`.
    private func noResponse(_ module: UInt8, _ why: String) -> UDSResult {
        log.note("module \(ISOTP.hexLine([module])): no response, \(why)")
        return .noResponse
    }

    /// Logs why the answer on CAN id `id` is not in an OBD result.
    private func leftOut(_ id: UInt16, _ why: String) {
        log.note("OBD \(String(id, radix: 16, uppercase: true)): answer left out, \(why)")
    }
}
