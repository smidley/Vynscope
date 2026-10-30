/// What a command cut by a drop waits behind until the link is back. `open` lets every waiter through, `fail`
/// throws to every waiter, a waiter whose deadline comes first gets `LinkError.timeout`, and one whose task is
/// cancelled gets `CancellationError`.
public final class ReadyGate {
    private var isOpen = false  // not `open`, which would clash with `open()`
    /// The suspended waiters, keyed so that each one's timer can find its own.
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextWaiter = 0

    public init() {}

    /// Returns at once when the gate is open; otherwise suspends until `open`, `fail`, `deadline` or a cancel.
    public func wait(until deadline: ContinuousClock.Instant) async throws {
        guard !isOpen else { return }
        let id = nextWaiter
        nextWaiter += 1
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { waiters.removeValue(forKey: id)?.resume(throwing: LinkError.timeout) }
        }
        defer { timer.cancel() }  // a timer that outlived its wait must not fire later
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            // Any thread may cancel; the waiter is resumed on the main actor, if it is still waiting.
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
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
