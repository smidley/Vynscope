/// The adapter seam: everything above the transport talks to the car through this one call.
public protocol CommandLink: AnyObject {
    /// Sends one command (without the trailing `\r`) and returns the response lines up to and
    /// excluding the `>` prompt: trimmed, with blank lines and any echo of the command dropped.
    func send(_ command: String, timeout: Duration) async throws -> [String]
}

public enum LinkError: Error, Equatable {
    case timeout, disconnected, adapterError(String)
    /// The link dropped and is back; the command that was cut must be sent again by a caller that first restores
    /// the adapter.
    case reconnected
}

/// Why `Diag` stopped: after a reconnect, or before sending a request it does not allow.
public enum DiagError: Error, Equatable {
    /// A standard OBD request in a mode `Diag.obd` does not send, or an empty one, refused before anything was sent:
    /// only the reads of modes 01, 03, 07 and 09 go to every controller. The value is the request.
    case notAllowed([UInt8])
    /// The car that answered after the reconnect is not the one the flow holds; the value is the VIN it gave.
    case differentCar(String)
    /// After the reconnect the adapter answered but the car never gave its VIN: every try found the modules silent
    /// or the bus in error, so the work stopped rather than go on against a car it could not check.
    case carSilent
    /// The link dropped again during every restoration one operation is allowed, so the operation was given up
    /// rather than tried for ever.
    case keptDropping
}
