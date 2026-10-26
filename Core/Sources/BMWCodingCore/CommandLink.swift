/// The adapter seam: everything above the transport talks to the car through this one call.
public protocol CommandLink: AnyObject {
    /// Sends one command (without the trailing `\r`) and returns the response lines up to and
    /// excluding the `>` prompt: trimmed, with blank lines and any echo of the command dropped.
    func send(_ command: String, timeout: Duration) async throws -> [String]
}

public enum LinkError: Error, Equatable {
    case timeout, disconnected, adapterError(String)
}
