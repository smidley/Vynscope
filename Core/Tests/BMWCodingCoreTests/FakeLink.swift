@testable import BMWCodingCore

/// A scripted adapter for tests. `respond` is the whole script: it answers every command, including
/// the ones a test does not care about (usually with `["OK"]`), and may throw to simulate a dead link.
/// Every command is recorded in `sent`, in order, with the timeout it was sent with in `timeouts`.
final class FakeLink: CommandLink {
    private(set) var sent: [String] = []
    private(set) var timeouts: [Duration] = []
    private let respond: (String) throws -> [String]

    init(respond: @escaping (String) throws -> [String]) { self.respond = respond }

    func send(_ command: String, timeout: Duration) async throws -> [String] {
        sent.append(command)
        timeouts.append(timeout)
        return try respond(command)
    }
}
