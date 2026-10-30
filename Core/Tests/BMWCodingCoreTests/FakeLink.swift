@testable import BMWCodingCore

/// A scripted adapter for tests. `respond` is the whole script: it answers every command, including
/// the ones a test does not care about (usually with `["OK"]`), and may throw to simulate a dead link.
/// Every command is recorded in `sent`, in order, with the timeout it was sent with in `timeouts`.
final class FakeLink: CommandLink {
    private(set) var sent: [String] = []
    private(set) var timeouts: [Duration] = []
    /// When set, the `n`th call to `send` from then on is cut by a drop: it is recorded, gets no answer from
    /// `respond` and throws `LinkError.reconnected`, once; this is then nil again.
    var dropAfter: Int?
    private let respond: (String) throws -> [String]

    init(respond: @escaping (String) throws -> [String]) { self.respond = respond }

    func send(_ command: String, timeout: Duration) async throws -> [String] {
        sent.append(command)
        timeouts.append(timeout)
        if let n = dropAfter {
            dropAfter = n > 1 ? n - 1 : nil
            if n == 1 { throw LinkError.reconnected }
        }
        return try respond(command)
    }
}
