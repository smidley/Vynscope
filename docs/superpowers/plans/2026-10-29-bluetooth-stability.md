# Bluetooth Link Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The link to the OBDLink CX reconnects by itself after a drop and the work in flight carries on; the owner is warned while the connection is bad; after one minute without the adapter the app stops and asks them to reconnect.

**Architecture:** The resilience decisions live in a pure `LinkPolicy` (drop, reconnect, give-up, keep-alive, probe, signal warning) that `BLELink` feeds with events and whose actions it carries out against CoreBluetooth, so the decisions are tested without a radio. A command cut by a drop waits for the reconnect behind a small `ReadyGate` and then ends in a new `LinkError.reconnected`; `Diag` catches it, restores the adapter (setup, VIN check, addressing) and reruns the whole operation, three times at most. The app shows the reconnecting state and the warning, and offers Reconnect after a give-up.

**Tech Stack:** Swift 6 strict concurrency with `defaultIsolation(MainActor.self)` in both package and app; Swift Testing; CoreBluetooth; SwiftUI on iOS 26 / macOS 26; xcodegen 2.45.

**Spec:** `docs/superpowers/specs/2026-10-28-bluetooth-stability-design.md`

## Global Constraints

- No new wire traffic to the car and nothing that writes: the allowed list stays adapter setup, `0x22`, `0x19 0x02` (mask FF), `0x3E`, `0x10 0x03` and the standard OBD modes 01/03/07/09 on `7DF`. The keep-alive and the probe are the adapter-only `ATI`; a bare carriage return is never sent on its own.
- The link never resends a command by itself; only `Diag` reruns operations, after restoring the adapter.
- Every drop, reconnect, give-up and signal warning is one log line with its time; nothing about the car's data is logged by the link.
- No test touches CoreBluetooth or a real adapter: `FakeLink` and plain values only. The real VIN never appears; the placeholder is `WBY73AW04RFFAKE19`.
- No new dependencies. Both targets build with no warnings after every task.
- Give-up window `60` seconds, idle keep-alive after `30` seconds, keep-alive and probe timeout `2` seconds, two keep-alive misses or one probe miss is a drop, signal readings every `5` seconds, weak below `-85` dBm for two readings, clear above `-80` dBm for two readings, VIN re-read every `2` seconds up to `30` times, three restorations per operation.

## Review Focus

- A drop while a connect is still in progress (before `ready`): it must fail that connect as today, never start a reconnect. Pinned in Task 2 (`aDropBeforeReadyIsNotAReconnect`).
- A keep-alive falling due while a command is in flight: it must be skipped, never interleaved with the command. Pinned in Task 2 (`noKeepAliveWhileACommandIsInFlight`).
- A second drop during the restoration itself: it must count toward the cap and never recurse into a second restoration. Pinned in Task 4 (`aDropDuringTheRestorationCountsAndDoesNotRecurse`).
- The owner pressing Disconnect while reconnecting: the waiting command must fail with `disconnected`, the link must end `off`, nothing may stay suspended. Pinned in Task 1 (`failingTheGateThrowsToEveryWaiter`) and Task 2 (`anOwnerDisconnectEndsTheReconnect`).
- A signal that hovers around the threshold: the warning must not flap. Pinned in Task 2 (`theSignalWarningHasHysteresis`).

---

### Task 1: The reconnect error, the different-car error and the ready gate

**Files:**
- Modify: `Core/Sources/BMWCodingCore/CommandLink.swift`
- Create: `Core/Sources/BMWCodingCore/ReadyGate.swift`
- Modify: `Core/Sources/BMWCodingCore/Mechanic.swift:185-190` (the exhaustive `switch` over `LinkError`)
- Modify: `App/Flow.swift:347-355` (`describe`)
- Test: `Core/Tests/BMWCodingCoreTests/ReadyGateTests.swift`

**Interfaces:**
- Produces: `LinkError.reconnected` (a command cut by a drop ends with it once the link is back); `public enum DiagError: Error, Equatable { case differentCar(String) }` in `CommandLink.swift`, the associated value being the VIN that answered; `public final class ReadyGate` with `func wait(until deadline: ContinuousClock.Instant) async throws`, `func open()`, `func fail(_ error: LinkError)`.

- [ ] **Step 1: Write the failing tests**

```swift
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
    async let waited: Void = gate.wait(until: .now + .seconds(5))
    await Task.yield()
    gate.fail(.disconnected)
    await #expect(throws: LinkError.disconnected) { try await waited }
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter ReadyGateTests`
Expected: FAIL to compile, `ReadyGate` not defined.

- [ ] **Step 3: Add the cases and the gate**

In `CommandLink.swift`: `LinkError` gains `case reconnected` (doc: "the link dropped and is back; the command that was cut must be sent again by a caller that first restores the adapter") and the file gains `DiagError`. In `ReadyGate.swift`: a main-actor class holding `private var open = false` and `private var waiters: [CheckedContinuation<Void, any Error>]`; `wait(until:)` returns at once when open, otherwise registers a continuation and a timer task that resumes it with `LinkError.timeout` at the deadline (cancelled on any other resume, the way `BLELink.wait` does it); `open()` sets `open` and resumes every waiter; `fail(_:)` resumes every waiter with the error and leaves the gate closed; a `func close()` sets `open = false` for the next reconnect.

In `Mechanic.swift:185`, add `case .reconnected: "reconnected"` to the switch. In `Flow.describe`, add `case LinkError.reconnected: "The adapter reconnected; try again"` and `case DiagError.differentCar: "A different car answered after the reconnect"`.

- [ ] **Step 4: Run the tests to verify they pass, and the suite**

Run: `cd Core && swift test`
Expected: all pass (278 + 4).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/CommandLink.swift Core/Sources/BMWCodingCore/ReadyGate.swift Core/Sources/BMWCodingCore/Mechanic.swift App/Flow.swift Core/Tests/BMWCodingCoreTests/ReadyGateTests.swift
git commit -m "Core: LinkError.reconnected, DiagError.differentCar and the ReadyGate a cut command waits behind"
```

---

### Task 2: `LinkPolicy`, the decisions without the radio

**Files:**
- Create: `Core/Sources/BMWCodingCore/LinkPolicy.swift`
- Test: `Core/Tests/BMWCodingCoreTests/LinkPolicyTests.swift`

**Interfaces:**
- Produces:

```swift
/// The link's resilience decisions, with no CoreBluetooth in them: what to do on a drop, an answer, a tick of the
/// clock or a signal reading. `BLELink` feeds it events and carries out the actions it returns.
public struct LinkPolicy: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, connecting, ready, reconnecting(since: Date) }
    public enum Event: Equatable, Sendable {
        case connectStarted(Date)        // `connect()` began; a drop now is a failed connect, not a reconnect
        case connectFailed(Date)         // `connect()` threw; back to idle
        case becameReady(Date)           // a connect or a reconnect finished
        case dropped(Date, reason: String)  // the system reported the adapter gone, or Bluetooth went off
        case commandSent(Date)           // a caller's command went out; the idle clock restarts
        case commandAnswered(Date)       // its prompt arrived
        case commandTimedOut(Date)       // its prompt did not arrive while the link said ready
        case keepAliveAnswered(Date), keepAliveMissed(Date)
        case probeAnswered(Date), probeMissed(Date)
        case tick(Date)                  // about once a second while ready or reconnecting
        case signal(Int, Date)           // an RSSI reading in dBm
        case disconnectedByOwner(Date)
    }
    public enum Action: Equatable, Sendable {
        case startReconnect              // ask the system to connect to the kept adapter
        case giveUp(String)              // cancel the pending connect, fail the waiters, show the message
        case sendKeepAlive               // `ATI` with the 2-second timeout, answered or missed
        case sendProbe                   // the same command after a timeout, answered or missed
        case failTimedOut                // the probe answered: the timed-out command fails with `timeout`
        case warn(String?)               // the warning line to show, or nil to clear it
        case log(String)                 // one log line
    }
    public static let window: Duration = .seconds(60)
    public static let idleBeforeKeepAlive: Duration = .seconds(30)
    public static let signalEvery: Duration = .seconds(5)
    public static let weakSignal = -85, goodSignal = -80  // ponytail: calibration knobs for the i4's cabin
    public private(set) var phase: Phase = .idle
    public private(set) var warning: String?
    public private(set) var reconnects = 0
    public init()
    public mutating func handle(_ event: Event) -> [Action]
}
```

- [ ] **Step 1: Write the failing tests**

One `@Test` per line, each building a policy, feeding events and asserting the returned actions and `phase` (use `let t0 = Date(timeIntervalSince1970: 0)` and `t0.addingTimeInterval(_:)`):

```swift
@Test func aDropWhileReadyStartsAReconnect()  // becameReady(t0), dropped(t0+10, "gone") → [.log("adapter dropped: gone"), .startReconnect]; phase == .reconnecting(since: t0+10); warning == nil
@Test func aDropNotesTheLastSignalReading()  // becameReady(t0), signal(-71, t0+5), dropped(t0+10, "gone") → first action .log("adapter dropped: gone, signal -71 dBm")
@Test func aDropBeforeReadyIsNotAReconnect()  // connectStarted(t0), dropped(t0+1, "gone") → [] and phase == .idle
@Test func becomingReadyAgainCountsAndWarns()  // ready, dropped at t0+10, becameReady(t0+14) → [.log("adapter reconnected after 4 s"), .warn("The adapter dropped and reconnected")]; reconnects == 1; then commandAnswered(t0+20) → [.warn(nil)]
@Test func theWindowGivesUpAtSixtySeconds()  // ready, dropped t0, tick(t0+59) → []; tick(t0+60) → [.log("adapter did not come back in 60 s"), .giveUp("The adapter did not come back. Reconnect when it is in range.")]; phase == .idle
@Test func anOwnerDisconnectEndsTheReconnect()  // ready, dropped t0, disconnectedByOwner(t0+5) → [.log("disconnected by the owner")]; phase == .idle; a later tick(t0+70) → []
@Test func anIdleLinkIsKeptAlive()  // ready at t0, commandAnswered(t0); tick(t0+29) → []; tick(t0+30) → [.sendKeepAlive]; keepAliveAnswered(t0+31); tick(t0+60) → []; tick(t0+61) → [.sendKeepAlive]
@Test func noKeepAliveWhileACommandIsInFlight()  // ready t0, commandSent(t0+1), tick(t0+40) → []
@Test func twoMissedKeepAlivesAreADrop()  // ready t0, tick(t0+30) → sendKeepAlive, keepAliveMissed(t0+32) → [.log("keep-alive missed once")]; tick(t0+32) → [.sendKeepAlive]; keepAliveMissed(t0+34) → [.log("adapter dropped: no answer to the keep-alive"), .startReconnect]; phase == .reconnecting(since: t0+34)
@Test func oneMissThenAnAnswerIsNotADrop()  // as above but keepAliveAnswered after the first miss → no startReconnect; a later miss counts as the first again
@Test func aTimeoutWhileReadyIsProbed()  // ready, commandSent(t0), commandTimedOut(t0+2) → [.sendProbe]; probeAnswered(t0+3) → [.failTimedOut]; phase == .ready
@Test func aMissedProbeIsADrop()  // ready, commandSent(t0), commandTimedOut(t0+2) → [.sendProbe]; probeMissed(t0+4) → [.log("adapter dropped: no answer to the probe"), .startReconnect]
@Test func theSignalWarningHasHysteresis()  // ready; signal(-90, t0) → []; signal(-90, t0+5) → [.log("signal weak: -90 dBm"), .warn("Weak Bluetooth signal")]; signal(-82, t0+10) → []; signal(-79, t0+15) → []; signal(-79, t0+20) → [.warn(nil)]; signal(-86, t0+25) → []; signal(-86, t0+30) → [.log(…), .warn("Weak Bluetooth signal")]
@Test func theSignalWarningShowsOverThePendingReconnectWarning()  // ready, dropped, becameReady → .warn("The adapter dropped and reconnected"); signal(-90) twice → .warn("Weak Bluetooth signal"); signal(-79) twice → .warn("The adapter dropped and reconnected") (still pending, no command answered); commandAnswered → .warn(nil)
@Test func aReconnectWarningClearedFirstLeavesNoWarningWhenTheSignalRecovers()  // as above but commandAnswered before the good readings → the good readings end in .warn(nil)
@Test func nothingHappensWhileIdle()  // every event except connectStarted on a fresh policy → [] and phase == .idle
@Test func aFailedConnectGoesBackToIdle()  // connectStarted(t0), connectFailed(t0+3) → []; phase == .idle; a later tick → []
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter LinkPolicyTests`
Expected: FAIL to compile, `LinkPolicy` not defined.

- [ ] **Step 3: Implement `LinkPolicy`**

A value type with the private state it needs: the time of the last command sent and answered, whether a command is in flight, the count of keep-alive misses in a row, whether a probe is pending, the two most recent signal readings, and whether the current warning is the reconnect one. `handle` is one `switch` over the event that updates the state and returns the actions in the order the tests list them. The log strings are exactly the tests'. A `.dropped` in `.connecting` or `.idle` returns `[]`; `.becameReady` from `.connecting` returns `[]`; `.becameReady` from `.reconnecting` logs the whole seconds since `since`.

- [ ] **Step 4: Run the tests to verify they pass, and the suite**

Run: `cd Core && swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/LinkPolicy.swift Core/Tests/BMWCodingCoreTests/LinkPolicyTests.swift
git commit -m "Core: LinkPolicy, the link's drop, reconnect, keep-alive, probe and signal decisions, tested without a radio"
```

---

### Task 3: `BLELink` carries the policy out

**Files:**
- Modify: `Core/Sources/BMWCodingCore/BLELink.swift`
- Modify: `App/ConnectStep.swift:48-56` (`stateText`, one case, so the app builds)
- Modify: `App/Flow.swift:33` (`let link = BLELink()` becomes a link with the log)

**Interfaces:**
- Consumes: `LinkPolicy`, `ReadyGate`, `LinkError.reconnected` from Tasks 1 and 2.
- Produces: `BLELink.State` gains `case reconnecting(since: Date)`; `public init(log: Log? = nil)`; `public private(set) var warning: String?` (the policy's, observable); `public private(set) var reconnects: Int`; `send` while `reconnecting` waits for the link and throws `LinkError.reconnected`; a command cut by a drop does the same.

No unit test covers this task: it is the CoreBluetooth layer the design keeps thin. Its check is the two builds and the in-car list in Task 6.

- [ ] **Step 1: The reconnecting state and the wait behind the gate**

Add the state case and `private let gate = ReadyGate()`, `private var policy = LinkPolicy()`, `private let log: Log?`. In `connect()`, feed `.connectStarted(.now)`; on success feed `.becameReady(.now)` and `gate.open()`; on failure feed `.connectFailed(.now)`. In `send`: when `state` is `.reconnecting`, `try await gate.wait(until: dropInstant + .seconds(60))`, then `throw LinkError.reconnected`. In `centralManager(_:didDisconnectPeripheral:error:)`: instead of `tearDown(.failed(…))`, when the policy returns `.startReconnect` for `.dropped(.now, reason:)`, keep `adapter`, clear the two characteristics, set `state = .reconnecting(since:)` and record `dropInstant = ContinuousClock.now` (the gate and the prepare deadline use the continuous clock; the policy's `since` is a `Date` for the log and the views), `gate.close()`, resume the in-flight waiter with a private `cut` error that `send` catches and turns into the same gate wait and `LinkError.reconnected`; then `central.connect(adapter)`. When the policy returns nothing (a drop during a connect), behave as today. `centralManagerDidUpdateState` with Bluetooth off during `reconnecting` or `ready` feeds `.dropped(.now, reason: "Bluetooth is off")` the same way.

- [ ] **Step 2: Finishing a reconnect**

In `centralManager(_:didConnect:)` while `reconnecting`, run the part of `establish` that follows the connection (services, characteristics, identity, subscribe), factored out as `private func prepare(_ peripheral: CBPeripheral, by deadline: ContinuousClock.Instant) async throws`, with the deadline at `dropInstant + .seconds(60)`. On success: `state = .ready`, feed `.becameReady(.now)`, `gate.open()`. On failure: feed nothing and let the tick's give-up or the deadline end it: `tearDown(.failed(message))` with the policy's give-up message, `gate.fail(.disconnected)`.

- [ ] **Step 3: The tick, the keep-alive, the probe and the signal**

A `private var ticker: Task<Void, Never>?` started when the link becomes ready and cancelled by `tearDown`: a loop sleeping 1 second that feeds `.tick(.now)` and, every fifth tick while `ready`, calls `adapter.readRSSI()`; `peripheral(_:didReadRSSI:error:)` feeds `.signal(Int(truncating: RSSI), .now)`. Carrying out actions: `.sendKeepAlive` and `.sendProbe` send `"ATI"` through the same `send` path with a 2-second timeout, marked internal so that they do not feed `.commandSent`, and feed `.keepAliveAnswered`/`.keepAliveMissed` or `.probeAnswered`/`.probeMissed`; a keep-alive that finds `busy` set is skipped. `.failTimedOut` resumes the timed-out `send` with `LinkError.timeout`. `.giveUp(message)`: `central.cancelPeripheralConnection(adapter)`, `tearDown(.failed(message))`, `gate.fail(.disconnected)`. `.warn(text)` sets `warning`. `.log(text)` calls `log?.note("link: \(text)")`. A caller's `send` feeds `.commandSent` before the write and `.commandAnswered` when the prompt arrives; a timeout while `ready` feeds `.commandTimedOut` instead of throwing, and the `send` stays suspended until `.failTimedOut` or the reconnect path ends it.

- [ ] **Step 4: Disconnect by the owner and the log**

`disconnect()` feeds `.disconnectedByOwner(.now)` before `tearDown(.off)`, and `tearDown` also calls `gate.fail(.disconnected)` and cancels the ticker. Add `public init(log: Log? = nil)`; in `App/Flow.swift` the stored `let link = BLELink()` becomes `let link: BLELink` assigned `BLELink(log: log)` in `init()` (declare `log` first). In `App/ConnectStep.swift`'s `stateText`, add `case .reconnecting: "Reconnecting…"`.

- [ ] **Step 5: Build both targets and run the suite**

Run: `make project && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build 2>&1 | grep -E "error:|warning:"; xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet build 2>&1 | grep -E "error:|warning:"; cd Core && swift test`
Expected: nothing printed by either build (the AppIntents notice aside); all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/BMWCodingCore/BLELink.swift App/ConnectStep.swift App/Flow.swift
git commit -m "Core: the link reconnects on a drop, keeps the adapter awake, probes a timeout, reads the signal and gives up after a minute"
```

---

### Task 4: `Diag` restores the adapter and reruns the cut operation

**Files:**
- Modify: `Core/Sources/BMWCodingCore/Diag.swift`
- Modify: `Core/Tests/BMWCodingCoreTests/FakeLink.swift` (one convenience)
- Test: `Core/Tests/BMWCodingCoreTests/DiagTests.swift` (the existing file; add tests)

**Interfaces:**
- Consumes: `LinkError.reconnected`, `DiagError.differentCar` (Task 1); `VIN.read(diag:)` as it is.
- Produces: `public var expectedVIN: String?` on `Diag` (the car the flow holds; nil before a car is read); `public var sleep: (Duration) async throws -> Void` (defaults to `Task.sleep(for:)`; tests stub it); `public static let vinRetryInterval: Duration = .seconds(2)`, `public static let vinRetries = 30`, `public static let restorations = 3`. Every public operation (`setUp`, `select`, `readDID`, `readFaults`, `testerPresent`, `enterExtendedSession`, `obd`) reruns itself after a `reconnected`.

- [ ] **Step 1: Write the failing tests**

Give `FakeLink` an `init(script: [(String) throws -> [String]])`-free convenience instead: keep `respond`, and add `var dropAfter: Int?` — when set, the `n`th call to `send` throws `LinkError.reconnected` once and clears itself; tests then script the restoration answers through `respond` by inspecting `sent`. Tests (the fixture VIN is `WBY73AW04RFFAKE19`; `ELM.initSequence`, `ELM.bmwSequence` and `ELM.obdSequence` are the real constants):

```swift
@Test func aCutReadIsRerunAfterTheSetupTheVINAndTheSelectAreRestored() async throws
// setUp, select(module: 0x40), expectedVIN = fixture; dropAfter set so the `22 F1 90`-style read's send throws .reconnected once;
// respond answers ATZ/init/identities with OK or text, the VIN read with the fixture VIN frames, the select with OK, the rerun with a positive;
// assert: result positive; `sent` after the drop is exactly: "ATZ", ELM.initSequence…, "ATI","STI","STDI", the VIN read's commands, "ATCRA 640", "ATFCSD 40 30 00 00", then the original read frame again; and the read frame appears exactly twice in all of `sent`.

@Test func aCutOBDRequestIsRerunInOBDAddressing() async throws
// setUp, obd([0x01,0x00]) with the drop on its send; assert the rerun is preceded by ELM.obdSequence (not a select) and `addressing == .obd` afterwards.

@Test func aDifferentCarAfterTheReconnectFailsTheOperation() async throws
// expectedVIN = fixture; the restoration's VIN read answers another VIN → `DiagError.differentCar(other)` thrown; `sent` has no rerun of the read.

@Test func aSilentCarIsAskedAgainEveryTwoSecondsUntilThirtyTimes() async throws
// sleep stubbed to record durations; the VIN read answers NO DATA 29 times then the fixture → the operation succeeds and the recorded sleeps are 29 × .seconds(2); with NO DATA 30 times → LinkError.disconnected and 30 sleeps.

@Test func aFourthReconnectFailsWithDisconnected() async throws
// the read's send throws .reconnected four times in a row (every rerun) → LinkError.disconnected; the restoration ran three times (count the "ATZ"s: 3 after the first setUp).

@Test func aDropDuringTheRestorationCountsAndDoesNotRecurse() async throws
// the first restoration's "ATZ" throws .reconnected → that counts as the second restoration, no nested one; with two more the cap trips: "ATZ" never exceeds 1 + 3 sends.

@Test func aCompletedCommandIsNeverRepeated() async throws
// a read whose reply arrived, followed by a drop on the *next* operation: `sent` holds the first read frame once.

@Test func setUpItselfRerunsAfterAReconnect() async throws
// setUp's "ATZ" throws .reconnected once → setUp succeeds and "ATZ" was sent twice, no VIN read (expectedVIN nil).
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter DiagTests`
Expected: the new tests fail (`dropAfter`, `expectedVIN`, `sleep` undefined, or `reconnected` propagates).

- [ ] **Step 3: Implement the restoration**

Factor the body of `setUp()` into `private func rawSetUp() async throws -> AdapterInfo`, the body of `select(module:)` into `private func rawSelect(_ module: UInt8) async throws`, the OBD switch at the top of `obd(_:)` into `private func rawSwitchToOBD() async throws`. Add:

```swift
/// Runs `operation`; when the link reports a reconnect, restores the adapter and runs it again from its start,
/// `restorations` times at most, then fails with `LinkError.disconnected`.
private func resilient<T>(_ operation: () async throws -> T) async throws -> T
```

It loops `restorations + 1` times: `do { return try await operation() } catch LinkError.reconnected { if restoring { throw } ; try await restore() }` where a `reconnected` thrown inside `restore()` is caught by the loop as the next attempt (so a drop during the restoration counts and never nests), and after the last attempt it throws `LinkError.disconnected`. Every public operation becomes `try await resilient { try await raw… }`.

```swift
/// After a reconnect: the setup again, the car checked, the addressing put back as it was.
private func restore() async throws
```

Remembers `wasOBD = addressing == .obd` and `module = selected`, sets `restoring = true` (cleared in a `defer`), runs `rawSetUp()`, then when `expectedVIN != nil` reads `VIN.read(diag: self)` up to `vinRetries` times with `sleep(vinRetryInterval)` between tries on `VINError.noVIN`, throwing `LinkError.disconnected` when the tries run out and `DiagError.differentCar(vin)` when it differs; then `rawSwitchToOBD()` when `wasOBD`, else `rawSelect(module)` when `module` was set. `VIN.read` goes through the public operations, which do not catch while `restoring` is set.

- [ ] **Step 4: Run the tests to verify they pass, and the suite**

Run: `cd Core && swift test`
Expected: all pass; the existing Diag and Mechanic tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/Diag.swift Core/Tests/BMWCodingCoreTests/FakeLink.swift Core/Tests/BMWCodingCoreTests/DiagTests.swift
git commit -m "Core: Diag restores the adapter after a reconnect, re-checks the car and reruns the operation, three times at most"
```

---

### Task 5: The app shows it and offers Reconnect

**Files:**
- Modify: `App/Flow.swift` (`readCar`, `forgetCar`, the catch sites that call `Self.describe`, a new `reconnect()`)
- Modify: `App/VynscopeApp.swift` (`FlowView` error block, `StepIndicator`)
- Modify: `App/ConnectStep.swift` (the warning line)
- Modify: `App/ModulesStep.swift:10-11`, `App/BackupStep.swift:54`, `App/AIStep.swift` (the health-check `ProgressView(step)`), `App/ChatView.swift` (the caption under a turn in progress)

**Interfaces:**
- Consumes: `BLELink.State.reconnecting`, `BLELink.warning`, `Diag.expectedVIN`, `DiagError.differentCar`, `LinkError.reconnected`.
- Produces: `Flow.reconnect()`; `Flow.explain(_ error: any Error) -> String` (instance; replaces `Self.describe` at the catch sites).

No unit test covers the views; the check is both builds and Task 6.

- [ ] **Step 1: The flow**

In `readCar`, after `self.vin = vin`, set `diag.expectedVIN = vin`; in `forgetCar`, `diag?.expectedVIN = nil`. Add `func explain(_ error: any Error) -> String`: `LinkError.disconnected` while `link.state` is `.failed(let message)` gives that message, otherwise `Self.describe(error)`; replace every `Self.describe(error)` at a catch site with `explain(error)`. In the same catch sites, a `DiagError.differentCar` also calls `forgetCar()` and sets `step = .connect`. Add:

```swift
/// After a give-up: connects to the adapter again and, when the same car answers, leaves the owner where they are
/// with the car still known; a different car, or none, forgets it and goes back to Connect.
func reconnect() async
```

It guards `!busy`, sets `busy`, clears `error`, runs `link.connect()` then `Diag(link:log:).setUp()` as `connect()` does, then `VIN.read`; equal to `vin` keeps `car`, `modules`, `lastBackup` and sets the new `diag` with `expectedVIN`; otherwise `forgetCar()`, `step = .connect`; errors go through `explain`.

- [ ] **Step 2: The views**

`FlowView`: under the error text, when `flow.link.state` is `.failed` and `flow.step != .connect`, a `Button("Reconnect") { Task { await flow.reconnect() } }` with `.buttonStyle(.borderedProminent)`, disabled while `flow.busy`. `StepIndicator` reads `@Environment(Flow.self)` and colors the Connect entry `Color.vynOrangeDark` when the link is `.reconnecting` or `flow.link.warning != nil` (the current step's orange still wins for the current step). `ConnectStep`: a `Text(warning)` in `.vyn(.footnote)` and `Color.vynOrangeDark` under the adapter row when `flow.link.warning` is set. `ModulesStep`: the "Scanning · …" text reads "Reconnecting to the adapter…" while the link is `.reconnecting`; `BackupStep`'s progress label and `AIStep`'s health-check `ProgressView` label likewise; `ChatView`'s caption under the turn in progress likewise. The warning string and the reconnecting string are those exact texts.

- [ ] **Step 3: Build both targets and run the suite**

Run: the Task 3 Step 5 command.
Expected: nothing printed by either build; all tests pass.

- [ ] **Step 4: Commit**

```bash
git add App/Flow.swift App/VynscopeApp.swift App/ConnectStep.swift App/ModulesStep.swift App/BackupStep.swift App/AIStep.swift App/ChatView.swift
git commit -m "App: Reconnecting… on every step that waits on the adapter, the signal warning, and Reconnect after a give-up"
```

---

### Task 6: Scott's in-car verification

**Files:** none; a checklist for the owner with the adapter in the car.

- [ ] **Step 1: The three drops**

With the car on and the app on the Modules step scanning: walk the phone out of range until "Reconnecting…" shows, come back; expect the scan to continue and "The adapter dropped and reconnected" to show until the next answer. Repeat during a backup. Repeat during a chat turn's lookup.

- [ ] **Step 2: The give-up and Reconnect**

Pull the adapter during a backup and leave it out for more than a minute; expect "The adapter did not come back. Reconnect when it is in range." and the Reconnect button; plug it in and press it; expect the car still known and the Backup step still there.

- [ ] **Step 3: Ignition cycle and the sleeping adapter**

Turn the ignition off and on during a scan; expect the reconnect to wait for the modules and continue, or "The car did not answer after the adapter reconnected. Is the ignition on?" if the car stays silent. Leave the app idle on the Car step for ten minutes; expect the adapter still connected (the keep-alive) and the log showing no drop.

- [ ] **Step 4: The signal warning and the log**

Put the phone in the back of the car; expect "Weak Bluetooth signal" within ten seconds and its clearing when the phone returns. Open the Log window: one line per drop, reconnect, give-up and warning, with times, and nothing from the car's data in those lines.

- [ ] **Step 5: The iPhone locked**

Start a backup, lock the phone, wait; expect the backup to finish.

- [ ] **Step 6: An ignition cycle while idle**

Sit idle on a step, cycle the ignition (or crank the engine), then run a scan; expect the scan to work after a short restoration.

- [ ] **Step 7: Reconnect while the modules wake**

When Reconnect shows after an ignition cycle, press it while the modules are still waking up; expect the same car back, or "No module answered with a VIN. Is the ignition on?" on the Connect step, with the car forgotten until it is read again.

- [ ] **Step 8: The VIN wait is not a hang**

After an ignition cycle during a scan or a backup, watch the progress: it can sit still for up to about two minutes while the restoration waits for the car's VIN. Expect the work to go on afterwards, or the car-silent message.
