/// What a module made of one UDS request.
public enum UDSResult: Equatable, Sendable {
    /// The whole response payload, starting with the response service id (the request's plus `0x40`).
    case positive([UInt8])
    /// The negative response code.
    case negative(UInt8)
    /// Nothing usable came back: silence, a message that never finished, or one too short to read.
    case noResponse
}

/// Adapter setup and UDS requests to one module at a time. The adapter is a single serial channel, so
/// callers make one call at a time; overlapping calls would mix up their replies.
public final class Diag {
    /// How long the adapter may take over one vehicle request.
    public var readTimeout: Duration = .milliseconds(1500)
    private let link: CommandLink
    private let log: Log
    /// The module the adapter's receive filter and flow-control address are set for, when known.
    private var selected: UInt8?

    public init(link: CommandLink, log: Log) {
        self.link = link
        self.log = log
    }

    /// Resets the adapter, applies `ELM.initSequence` and reads its identity. Throws
    /// `LinkError.adapterError("<command>: <answer>")` for the first setup command that does not answer `OK`.
    public func setUp() async throws -> AdapterInfo {
        selected = nil  // the reset wipes the adapter's filter
        _ = try await send("ATZ", timeout: .seconds(3))
        for command in ELM.initSequence { try await expectOK(command) }
        let elmVersion = try await identity("ATI")
        let firmware = try await identity("STI")
        let model = try await identity("STDI")
        return AdapterInfo(model: model, firmware: firmware, elmVersion: elmVersion)
    }

    /// Points the adapter at `module`: it passes on only that module's frames and sends its flow control
    /// to it. Does nothing when `module` is already the selected one.
    public func select(module: UInt8) async throws {
        guard module != selected else { return }
        selected = nil  // the adapter's state is unknown until both commands are acknowledged
        try await expectOK("ATCRA \(String(responseID(module), radix: 16, uppercase: true))")
        try await expectOK("ATFCSD \(ISOTP.hexLine([module])) 30 00 00")
        selected = module
    }

    /// Sends one UDS request to `module`, which must be set up and selected, and reads its whole answer,
    /// doing the flow-control round trip by hand when the answer has several frames. Throws
    /// `LinkError.adapterError` as soon as the adapter prints an error line.
    public func request(_ module: UInt8, _ payload: [UInt8]) async throws -> UDSResult {
        let result = try await exchange(module, payload)
        guard result == .negative(0x78) else { return result }
        // ponytail: one fixed wait and one re-ask; a module that stays pending longer reads as
        // .negative(0x78). Add a capped loop if a slow module turns up.
        log.note("module \(ISOTP.hexLine([module])) answered response pending (0x78), asking again in 500 ms")
        try await Task.sleep(for: .milliseconds(500))
        return try await exchange(module, payload)
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

    /// Sends TesterPresent (`0x3E`); true when the module confirms it.
    public func testerPresent(_ module: UInt8) async throws -> Bool {
        try await request(module, [0x3E, 0x00]) == .positive([0x7E, 0x00])
    }

    /// Asks `module` for the extended diagnostic session (`0x10 0x03`); true when it agrees.
    public func enterExtendedSession(_ module: UInt8) async throws -> Bool {
        guard case .positive(let payload) = try await request(module, [0x10, 0x03]) else { return false }
        return payload.starts(with: [0x50, 0x03])
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
            guard let service = bytes.first else { return noResponse(module, "empty answer") }
            guard service == 0x7F else { return .positive(bytes) }
            return bytes.count >= 3
                ? .negative(bytes[2])
                : noResponse(module, "negative answer cut short: \(ISOTP.hexLine(bytes))")
        case .needFlowControl(let expected):
            return noResponse(module, "only the first frame of \(expected) bytes arrived, even after flow control")
        case .incomplete(let received, let expected):
            return noResponse(module, "\(received) of \(expected) bytes arrived")
        case .empty:
            return noResponse(module, "received \(lines.isEmpty ? "nothing" : lines.joined(separator: " | "))")
        }
    }

    /// What the frames `module` sent in `lines` add up to. Other lines (text, other ids, NO DATA) are
    /// skipped; an adapter error line throws.
    private func assemble(_ lines: [String], from module: UInt8) throws -> Reassembly {
        var frames: [[UInt8]] = []
        for line in lines {
            switch ELM.parse(line) {
            case .frame(let id, let data) where id == responseID(module): frames.append(data)
            case .error(let text): throw LinkError.adapterError(text)
            case .frame, .text, .noData: break
            }
        }
        return ISOTP.reassemble(frames)
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
}
