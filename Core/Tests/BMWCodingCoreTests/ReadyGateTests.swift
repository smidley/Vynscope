import Testing
@testable import BMWCodingCore

@Test func openingTheGateReleasesEveryWaiter() async throws {
    let gate = ReadyGate()
    async let first: Void = gate.wait(until: .now + .seconds(5))
    async let second: Void = gate.wait(until: .now + .seconds(5))
    await Task.yield()
    gate.open()
    try await first; try await second  // both return
}

@Test func failingTheGateThrowsToEveryWaiter() async {
    let gate = ReadyGate()
    let waited = Task { try await gate.wait(until: .now + .seconds(5)) }  // #expect cannot capture an async let
    await Task.yield()
    gate.fail(.disconnected)
    await #expect(throws: LinkError.disconnected) { try await waited.value }
}

@Test func aWaitPastItsDeadlineThrowsTimeout() async {
    let gate = ReadyGate()
    await #expect(throws: LinkError.timeout) { try await gate.wait(until: .now + .milliseconds(20)) }
}

@Test func anOpenGateDoesNotWait() async throws {
    let gate = ReadyGate()
    gate.open()
    try await gate.wait(until: .now)  // returns at once
}
