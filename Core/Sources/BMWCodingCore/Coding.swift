import Foundation

public enum CodingError: Error, Equatable {
    /// A module answered none of five identifiers in a row. `after` is how many identifiers `Coding.read` had
    /// asked by then, the five included. `found` holds the data it had read from the module before that, by
    /// identifier; it is empty when the module never answered.
    case moduleStoppedAnswering(after: Int, found: [UInt16: [UInt8]] = [:])
    /// A module refused five identifiers in a row as not supported in the active session (`0x7F`) or under
    /// conditions not correct (`0x22`), and `Coding.read` could not have them answered in the extended session (see
    /// there). `after` and `found` as for `moduleStoppedAnswering`.
    case sessionRefused(after: Int, found: [UInt16: [UInt8]] = [:])
}

/// Reads the coding data of one module: the data identifiers that answer with data.
public enum Coding {
    /// The identifiers a first read of a module tries.
    public static let fullRange: ClosedRange<UInt16> = 0x3000...0x3FFF

    /// Asks `module` for each of `dids`, one request each in the order given, and returns the data of the ones
    /// it answers positively. Any other answer leaves its identifier out; a negative one is not an error.
    /// `progress` gets how many identifiers are done and how many there are (`dids.count`) after every one,
    /// the skipped ones too. Selects `module` on `diag` first, and `diag` is busy until this returns.
    ///
    /// The first time `module` says that the service is not supported in the active session (`0x7F`) or that
    /// conditions are not correct (`0x22`), this asks it for the extended session. If it agrees, that identifier
    /// is asked again. From then on, five identifiers in a row refused with either code end the read, unless the
    /// module agreed and this is the first time: then the session is asked for again and, if the module agrees,
    /// every identifier refused since it was first asked for is asked again, in order; the read goes on if none of
    /// them is refused again. TesterPresent goes out ahead of any read that comes more than two seconds after the
    /// last request to `module`, to hold the session; its answer is ignored.
    ///
    /// Throws `CodingError.moduleStoppedAnswering`, carrying what was read so far, when five identifiers in a
    /// row get no answer at all, `CodingError.sessionRefused`, likewise, when refusals end the read as above,
    /// `CancellationError` between two identifiers once the task is cancelled, and lets the `LinkError`s of `diag`
    /// through.
    public static func read(
        diag: Diag, module: UInt8, dids: [UInt16], progress: @escaping (Int, Int) -> Void
    ) async throws -> [UInt16: [UInt8]] {
        try await read(diag: diag, module: module, dids: dids, now: { ContinuousClock.now }, progress: progress)
    }

    /// `read` with the clock as a parameter, so that a test can move time.
    static func read(
        diag: Diag, module: UInt8, dids: [UInt16], now: () -> ContinuousClock.Instant,
        progress: (Int, Int) -> Void
    ) async throws -> [UInt16: [UInt8]] {
        try await diag.select(module: module)
        var found: [UInt16: [UInt8]] = [:]
        var silent = 0  // identifiers in a row that got no answer at all
        let refusals: [UDSResult] = [.negative(0x7F), .negative(0x22)]
        var refused = 0  // identifiers in a row refused in the active session; a 0x31 (no such identifier) is none
        var refusedDIDs: [UInt16] = []  // every identifier refused since the session was asked for, in order
        var sessionAsked = false
        var mayReenter = false  // the module agreed to the session, which has not been asked for again yet
        var lastRequest = now()
        // One read, preceded by TesterPresent when the module has heard nothing for over two seconds.
        func ask(_ did: UInt16) async throws -> UDSResult {
            if now() - lastRequest > .seconds(2) { _ = try await diag.testerPresent(module) }
            lastRequest = now()
            let result = try await diag.readDID(module, did)
            silent = result == .noResponse ? silent + 1 : 0
            return result
        }
        // Asks for the extended session, a request that holds off TesterPresent like a read; true when it is granted.
        func enterSession() async throws -> Bool {
            lastRequest = now()
            return try await diag.enterExtendedSession(module)
        }
        for (index, did) in dids.enumerated() {
            try Task.checkCancellation()  // between two requests, so no answer is left unread
            var result = try await ask(did)
            if !sessionAsked, refusals.contains(result) {
                sessionAsked = true
                mayReenter = try await enterSession()
                if mayReenter { result = try await ask(did) }
            }
            if case .positive(let data) = result { found[did] = data }
            if refusals.contains(result) { refusedDIDs.append(did) }
            refused = refusals.contains(result) ? refused + 1 : 0
            progress(index + 1, dids.count)
            if silent >= 5 { throw CodingError.moduleStoppedAnswering(after: index + 1, found: found) }
            if refused >= 5 {  // the session is gone: ask for it again this once, then ask again all that was refused
                guard mayReenter, try await enterSession() else {
                    throw CodingError.sessionRefused(after: index + 1, found: found)
                }
                mayReenter = false
                for earlier in refusedDIDs {
                    try Task.checkCancellation()  // between two requests, as above
                    let answer = try await ask(earlier)
                    if refusals.contains(answer) { throw CodingError.sessionRefused(after: index + 1, found: found) }
                    if case .positive(let data) = answer { found[earlier] = data }
                }
                refusedDIDs = []
                refused = 0
            }
        }
        return found
    }
}

/// The data identifiers each module answered, kept in a JSON file so that a later backup asks only for those. A
/// set belongs to one module at one version of its coding files, so a module whose coding files changed has none.
public struct RememberedSets: Codable, Equatable {
    /// The identifiers that answered, by `key`.
    public var sets: [String: [UInt16]]

    /// The key of a module's set: its address as two upper-case hex digits, `|`, then its coding files sorted and
    /// joined by commas, as in `56|CAFD_000006C9_024_002_013`.
    public static func key(address: UInt8, codingFiles: [String]) -> String {
        "\(ISOTP.hexLine([address]))|\(codingFiles.sorted().joined(separator: ","))"
    }

    /// The sets in the file at `url`. Empty when there is no file or it cannot be decoded, in which case the
    /// next `save` replaces it.
    public static func load(from url: URL) -> RememberedSets {
        (try? JSONDecoder().decode(RememberedSets.self, from: Data(contentsOf: url))) ?? RememberedSets(sets: [:])
    }

    /// Writes the sets to `url` as pretty-printed JSON with sorted keys, creating the folders on the way. The
    /// file is replaced as a whole, so a crash half-way leaves the old one.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The identifiers remembered for the module at `address` with these coding files, or `nil` when there are
    /// none.
    public func dids(address: UInt8, codingFiles: [String]) -> [UInt16]? {
        sets[Self.key(address: address, codingFiles: codingFiles)]
    }

    /// Remembers `dids` for the module at `address` with these coding files, replacing any set it had.
    public mutating func remember(_ dids: [UInt16], address: UInt8, codingFiles: [String]) {
        sets[Self.key(address: address, codingFiles: codingFiles)] = dids
    }
}
