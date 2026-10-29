/// What a command cut by a drop waits behind until the link is back. `open` lets every waiter through, `fail`
/// throws to every waiter, and a waiter whose deadline comes first gets `LinkError.timeout`.
public final class ReadyGate {
    private var isOpen = false  // not `open`, which would clash with `open()`
    /// The suspended waiters, keyed so that each one's timer can find its own.
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextWaiter = 0

    public init() {}

    /// Returns at once when the gate is open; otherwise suspends until `open`, `fail` or `deadline`.
    public func wait(until deadline: ContinuousClock.Instant) async throws {
        guard !isOpen else { return }
        let id = nextWaiter
        nextWaiter += 1
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { waiters.removeValue(forKey: id)?.resume(throwing: LinkError.timeout) }
        }
        defer { timer.cancel() }  // a timer that outlived its wait must not fire later
        // ponytail: a cancelled caller still waits for `open`, `fail` or the deadline, as in `BLELink.wait`. Add a
        // cancellation handler if one must not sit out the window.
        try await withCheckedThrowingContinuation { waiters[id] = $0 }
    }

    /// Opens the gate and lets every waiter through.
    public func open() {
        isOpen = true
        for waiter in waiters.values { waiter.resume() }
        waiters = [:]
    }

    /// Throws `error` to every waiter and leaves the gate closed.
    public func fail(_ error: LinkError) {
        isOpen = false
        for waiter in waiters.values { waiter.resume(throwing: error) }
        waiters = [:]
    }

    /// Closes the gate at the start of a reconnect, so that the next wait suspends.
    public func close() {
        isOpen = false
    }
}
