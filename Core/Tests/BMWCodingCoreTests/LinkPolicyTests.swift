import Foundation
import Testing
@testable import BMWCodingCore

private let t0 = Date(timeIntervalSince1970: 0)

/// The events of a connect that reaches ready at `date`.
private func ready(at date: Date = t0) -> [LinkPolicy.Event] { [.connectStarted(date), .becameReady(date)] }

private extension LinkPolicy {
    /// A policy that has handled `events`, their actions dropped.
    init(after events: [Event]) {
        self.init()
        for event in events { _ = handle(event) }
    }
}

@Test func aDropWhileReadyStartsAReconnect() {
    var policy = LinkPolicy(after: ready())
    #expect(policy.handle(.dropped(t0 + 10, reason: "gone")) == [.log("adapter dropped: gone"), .startReconnect])
    #expect(policy.phase == .reconnecting(since: t0 + 10))
    #expect(policy.warning == nil)
}

@Test func aDropNotesTheLastSignalReading() {
    var policy = LinkPolicy(after: ready() + [.signal(-71, t0 + 5)])
    #expect(policy.handle(.dropped(t0 + 10, reason: "gone")).first == .log("adapter dropped: gone, signal -71 dBm"))
}

@Test func aDropBeforeReadyIsNotAReconnect() {
    var policy = LinkPolicy(after: [.connectStarted(t0)])
    #expect(policy.handle(.dropped(t0 + 1, reason: "gone")) == [])
    #expect(policy.phase == .idle)
}

@Test func becomingReadyAgainCountsAndWarns() {
    var policy = LinkPolicy(after: ready() + [.dropped(t0 + 10, reason: "gone")])
    #expect(policy.handle(.becameReady(t0 + 14))
        == [.log("adapter reconnected after 4 s"), .warn("The adapter dropped and reconnected")])
    #expect(policy.reconnects == 1)
    #expect(policy.handle(.commandAnswered(t0 + 20)) == [.warn(nil)])
}

@Test func theWindowGivesUpAtSixtySeconds() {
    var policy = LinkPolicy(after: ready() + [.dropped(t0, reason: "gone")])
    #expect(policy.handle(.tick(t0 + 59)) == [])
    #expect(policy.handle(.tick(t0 + 60)) == [
        .log("adapter did not come back in 60 s"),
        .giveUp("The adapter did not come back. Reconnect when it is in range."),
    ])
    #expect(policy.phase == .idle)
}

@Test func aDropWhileReconnectingAsksAgainWithinTheSameWindow() {
    var policy = LinkPolicy(after: ready() + [.dropped(t0, reason: "gone")])
    #expect(policy.handle(.dropped(t0 + 5, reason: "again")) == [.log("adapter dropped: again"), .startReconnect])
    #expect(policy.phase == .reconnecting(since: t0))
    #expect(policy.handle(.tick(t0 + 60)) == [
        .log("adapter did not come back in 60 s"),
        .giveUp("The adapter did not come back. Reconnect when it is in range."),
    ])
}

@Test func aGiveUpClearsTheWarningAndKeepsTheReconnectCount() {
    var policy = LinkPolicy(after: ready() + [
        .dropped(t0 + 10, reason: "gone"), .becameReady(t0 + 14), .dropped(t0 + 20, reason: "gone"),
    ])
    #expect(policy.warning == "The adapter dropped and reconnected")
    #expect(policy.handle(.tick(t0 + 80)) == [
        .log("adapter did not come back in 60 s"),
        .giveUp("The adapter did not come back. Reconnect when it is in range."),
        .warn(nil),
    ])
    #expect(policy.reconnects == 1)
}

@Test func anOwnerDisconnectEndsTheReconnect() {
    var policy = LinkPolicy(after: ready() + [.dropped(t0, reason: "gone")])
    #expect(policy.handle(.disconnectedByOwner(t0 + 5)) == [.log("disconnected by the owner")])
    #expect(policy.phase == .idle)
    #expect(policy.handle(.tick(t0 + 70)) == [])
}

@Test func anOwnerDisconnectWhileReadyOrConnectingGoesIdleWithoutALogAndClearsTheWarning() {
    var fromReady = LinkPolicy(after: ready() + [.signal(-90, t0 + 1), .signal(-90, t0 + 2)])
    #expect(fromReady.handle(.disconnectedByOwner(t0 + 3)) == [.warn(nil)])
    #expect(fromReady.phase == .idle)
    var fromConnecting = LinkPolicy(after: [.connectStarted(t0)])
    #expect(fromConnecting.handle(.disconnectedByOwner(t0 + 1)) == [])
    #expect(fromConnecting.phase == .idle)
}

@Test func anIdleLinkIsKeptAlive() {
    var policy = LinkPolicy(after: ready() + [.commandAnswered(t0 + 10)])
    #expect(policy.handle(.tick(t0 + 39)) == [])
    #expect(policy.handle(.tick(t0 + 40)) == [.sendKeepAlive])
    _ = policy.handle(.keepAliveAnswered(t0 + 41))
    #expect(policy.handle(.tick(t0 + 70)) == [])
    #expect(policy.handle(.tick(t0 + 71)) == [.sendKeepAlive])
}

@Test func noKeepAliveWhileACommandIsInFlight() {
    var policy = LinkPolicy(after: ready() + [.commandSent(t0 + 1)])
    #expect(policy.handle(.tick(t0 + 40)) == [])
}

@Test func twoMissedKeepAlivesAreADrop() {
    var policy = LinkPolicy(after: ready())
    #expect(policy.handle(.tick(t0 + 30)) == [.sendKeepAlive])
    #expect(policy.handle(.keepAliveMissed(t0 + 32)) == [.log("keep-alive missed once")])
    #expect(policy.handle(.tick(t0 + 32)) == [.sendKeepAlive])
    #expect(policy.handle(.keepAliveMissed(t0 + 34))
        == [.log("adapter dropped: no answer to the keep-alive"), .startReconnect])
    #expect(policy.phase == .reconnecting(since: t0 + 34))
}

@Test func oneMissThenAnAnswerIsNotADrop() {
    var policy = LinkPolicy(after: ready())
    #expect(policy.handle(.tick(t0 + 30)) == [.sendKeepAlive])
    #expect(policy.handle(.keepAliveMissed(t0 + 32)) == [.log("keep-alive missed once")])
    #expect(policy.handle(.tick(t0 + 32)) == [.sendKeepAlive])
    #expect(policy.handle(.keepAliveAnswered(t0 + 33)) == [])  // no reconnect
    #expect(policy.handle(.tick(t0 + 63)) == [.sendKeepAlive])
    #expect(policy.handle(.keepAliveMissed(t0 + 65)) == [.log("keep-alive missed once")])  // the first again
    #expect(policy.phase == .ready)
}

@Test func aTimeoutWhileReadyIsProbed() {
    var policy = LinkPolicy(after: ready() + [.commandSent(t0)])
    #expect(policy.handle(.commandTimedOut(t0 + 2)) == [.sendProbe])
    #expect(policy.handle(.probeAnswered(t0 + 3)) == [.failTimedOut])
    #expect(policy.phase == .ready)
    #expect(policy.handle(.tick(t0 + 32)) == [])  // the answer restarted the idle clock
    #expect(policy.handle(.tick(t0 + 33)) == [.sendKeepAlive])  // and nothing is in flight any more
}

@Test func aMissedProbeIsADrop() {
    var policy = LinkPolicy(after: ready() + [.commandSent(t0)])
    #expect(policy.handle(.commandTimedOut(t0 + 2)) == [.sendProbe])
    #expect(policy.handle(.probeMissed(t0 + 4)) == [.log("adapter dropped: no answer to the probe"), .startReconnect])
}

@Test func theSignalWarningHasHysteresis() {
    var policy = LinkPolicy(after: ready())
    #expect(policy.handle(.signal(-90, t0)) == [])
    #expect(policy.handle(.signal(-90, t0 + 5)) == [.log("signal weak: -90 dBm"), .warn("Weak Bluetooth signal")])
    #expect(policy.handle(.signal(-82, t0 + 10)) == [])
    #expect(policy.handle(.signal(-79, t0 + 15)) == [])
    #expect(policy.handle(.signal(-79, t0 + 20)) == [.warn(nil)])
    #expect(policy.handle(.signal(-86, t0 + 25)) == [])
    #expect(policy.handle(.signal(-86, t0 + 30)) == [.log("signal weak: -86 dBm"), .warn("Weak Bluetooth signal")])
}

@Test func theSignalWarningShowsOverThePendingReconnectWarning() {
    var policy = LinkPolicy(after: ready() + [.dropped(t0 + 10, reason: "gone")])
    #expect(policy.handle(.becameReady(t0 + 14))
        == [.log("adapter reconnected after 4 s"), .warn("The adapter dropped and reconnected")])
    #expect(policy.handle(.signal(-90, t0 + 15)) == [])
    #expect(policy.handle(.signal(-90, t0 + 20)) == [.log("signal weak: -90 dBm"), .warn("Weak Bluetooth signal")])
    #expect(policy.handle(.signal(-79, t0 + 25)) == [])
    #expect(policy.handle(.signal(-79, t0 + 30)) == [.warn("The adapter dropped and reconnected")])  // still pending
    #expect(policy.handle(.commandAnswered(t0 + 31)) == [.warn(nil)])
}

@Test func aReconnectWarningClearedFirstLeavesNoWarningWhenTheSignalRecovers() {
    var policy = LinkPolicy(after: ready() + [
        .dropped(t0 + 10, reason: "gone"), .becameReady(t0 + 14), .signal(-90, t0 + 15), .signal(-90, t0 + 20),
    ])
    #expect(policy.handle(.commandAnswered(t0 + 21)) == [])  // the signal warning still shows
    #expect(policy.handle(.signal(-79, t0 + 25)) == [])
    #expect(policy.handle(.signal(-79, t0 + 30)) == [.warn(nil)])
}

@Test func nothingHappensWhileIdle() {
    let events: [LinkPolicy.Event] = [
        .connectFailed(t0), .becameReady(t0), .dropped(t0, reason: "gone"), .commandSent(t0), .commandAnswered(t0),
        .commandTimedOut(t0), .keepAliveAnswered(t0), .keepAliveMissed(t0), .probeAnswered(t0), .probeMissed(t0),
        .tick(t0), .signal(-90, t0), .disconnectedByOwner(t0),
    ]
    for event in events {
        var policy = LinkPolicy()
        #expect(policy.handle(event) == [])
        #expect(policy.phase == .idle)
    }
}

@Test func aFailedConnectGoesBackToIdle() {
    var policy = LinkPolicy(after: [.connectStarted(t0)])
    #expect(policy.handle(.connectFailed(t0 + 3)) == [])
    #expect(policy.phase == .idle)
    #expect(policy.handle(.tick(t0 + 100)) == [])
}
