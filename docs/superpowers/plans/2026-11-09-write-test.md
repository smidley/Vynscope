# Write test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the i4's roof functions and climate modules, write every coding identifier back unchanged, read each back, and report whether the module accepts a write, without ever changing the car.

**Architecture:** The identification parse is fixed first, so modules report their real coding files. ISO-TP gains the frames for sending a request longer than one frame. `Diag` gains one internal write that is sent once and never re-run, and a public battery-voltage read. A Core `WriteTest` prepares (reference backup, fresh read, comparison, voltage) and runs (session, write, read-back) with eligibility enforced inside Core. The app adds a Write test section to the module screen.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, SwiftUI for iOS and macOS 26, xcodegen, the OBDLink CX through the `CommandLink` seam.

**Spec:** `docs/superpowers/specs/2026-11-08-write-test-design.md`. Read it before starting any task.

## Global Constraints

- Wire allow-list after this plan: adapter setup and `ATRV`; `0x22`; `0x19 0x02` with mask `FF`; `0x3E`; `0x10 0x03`; standard OBD modes 01, 03, 07 and 09 on `7DF`; and `0x2E` from `WriteTest.run` only. Never `0x11`, `0x14`, `0x27`, `0x31`, any `0x10` other than `0x03`.
- Eligible: VIN prefix `WBY73`, and either address `0x56` with a coding file whose id is `00001D92`, or address `0x78` with a coding file whose id is `000051C9`, any version. A module `ModuleTable.isSigned` reports as signed is never eligible. `WriteTest` checks this itself in both `prepare` and `run`.
- `Diag.writeDID` is internal to the Core package. No public API sends a write with caller-chosen bytes.
- A write is sent once: not inside `resilient`, no re-ask after `0x78`, nothing repeated after `0x21`. A reconnect during a write is rethrown.
- Long listen: `ATST FF` before the frame that completes a write request, `ATST 32` after it.
- Voltage floor: 12.0 V, read with `ATRV`, checked in `prepare` and again at the start of `run`.
- The fresh read is never saved as a backup file. The reference is the newest backup in which the module is complete; a reference with no coding files is too old.
- The AI mechanic's tools do not change; nothing in this plan gives it a write.
- Tests use `FakeLink` only and never touch the car, Anthropic or OpenAI. Test VINs use `WBY73AW04RFFAKE19`. The real VIN, car logs and backup files are never committed.
- `@State` properties are declared with an initial value and never assigned in an `init` (SDK 27).
- Doc comments follow the codebase: full sentences on what and why; `ponytail:` comments mark a deliberate ceiling and its upgrade path.
- One commit per task, subject in the repo's style (`Core: ...`, `App: ...`), ending with a `Co-Authored-By` trailer naming your own model.

## Commands

- All Core tests: `cd Core && swift test`. One suite: `cd Core && swift test --filter SVKTests`.
- Mac build, not launched: `make project && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build`.
- iOS build: `xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios -quiet build`.

## Review Focus

1. A write sent twice, by a reconnect's rerun or a pending answer's re-ask: the write frame must appear once in `FakeLink.sent` and the run must end.
2. Bytes the module did not just give: any difference between the fresh read and the reference, including a missing identifier, must leave `FakeLink.sent` without a `2E` request.
3. An ineligible module reaching the wire: a wrong address, a wrong coding file, a signed module or another car must send nothing at all from `run`.
4. A module that answers the first frame with overflow, wait or nothing: no consecutive frame goes out and the answer is no answer.
5. A response pending before the final answer: the final answer in the same lines is the answer, a lone pending is no answer, and `ATST 32` follows either way.

---

### Task 1: The identification parse

**Files:**
- Modify: `Core/Sources/BMWCodingCore/SVK.swift` (`SVK.parse` and its doc comment)
- Modify: `Core/Tests/BMWCodingCoreTests/SVKTests.swift`
- Modify: `Core/Tests/BMWCodingCoreTests/DiscoveryTests.swift` (the two `F1 01` answers at lines 27 and 46)

**Interfaces:**
- Produces: `SVK.parse(_ payload: [UInt8]) -> [SVKEntry]`, same signature, new rule. Task 4 relies on `codingFiles` names of the form `CAFD_000051C9_004_036_002`.

- [ ] **Step 1: Replace the header tests**

Delete `toleratesTruncation`, `readsOnlyWholeEntries` and `ignoresTheEntryCountByte`. Change `parsesEntriesAndNames` to put `[0x01, 0x01, 0x00, 0x02]` before its two entries. Add:

```swift
private let hwel: [UInt8] = [0x01, 0x00, 0x00, 0x51, 0xC8, 0x01, 0x00, 0x00]
private let cafd: [UInt8] = [0x05, 0x00, 0x00, 0x51, 0xC9, 0x04, 0x24, 0x02]

@Test func readsTheCountAndTakesTheEntriesFromTheEnd() {
    let longHeader: [UInt8] = [0x01, 0x01, 0x00, 0x02] + [UInt8](repeating: 0xEE, count: 13)
    #expect(SVK.parse(longHeader + hwel + cafd).map(\.name)
        == ["HWEL_000051C8_001_000_000", "CAFD_000051C9_004_036_002"])
    let shortHeader: [UInt8] = [0x01, 0x01, 0x00, 0x01] + [UInt8](repeating: 0xEE, count: 4)
    #expect(SVK.parse(shortHeader + cafd).codingFiles == ["CAFD_000051C9_004_036_002"])
}

@Test func noEntriesWhenTheAnswerIsShorterThanItsCount() {
    #expect(SVK.parse([0x01, 0x01, 0x00, 0x02] + cafd).isEmpty)
    #expect(SVK.parse([0x01, 0x01, 0x00, 0x00] + cafd).isEmpty)
    #expect(SVK.parse([0x01, 0x01, 0x00]).isEmpty)
    #expect(SVK.parse([]).isEmpty)
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `cd Core && swift test --filter SVKTests`. Expected: the two new tests fail.

- [ ] **Step 3: Implement the rule in `SVK.parse`**

The entry count is payload bytes 2 and 3, big-endian. The entries are the payload's last count × 8 bytes, each `[class][id, 4 bytes][main][sub][patch]`. A payload shorter than 4 bytes plus its entries has none. Rewrite the doc comment: confirmed on the i4 on 2026-11-04, a 17-byte header on 20 modules and 8 bytes on 6, and this rule fits all 26.

- [ ] **Step 4: Bring the discovery fixtures to the new layout**

In `DiscoveryTests.swift`, each `F1 01` answer becomes `62 F1 01`, then `01 01`, then the count as `00 0N`, then the same entries, with the first frame's length byte and the frame split adjusted. The names the tests expect stay as they are.

- [ ] **Step 5: Run every Core test**

Run: `cd Core && swift test`. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/BMWCodingCore/SVK.swift Core/Tests/BMWCodingCoreTests/SVKTests.swift Core/Tests/BMWCodingCoreTests/DiscoveryTests.swift
git commit -m "Core: the installed-software table takes its count from bytes 2 and 3 and its entries from the end, as the i4 sends them"
```

### Task 2: Frames for sending

**Files:**
- Modify: `Core/Sources/BMWCodingCore/ISOTP.swift`
- Test: `Core/Tests/BMWCodingCoreTests/ISOTPTests.swift`

**Interfaces:**
- Produces, used by Task 3:
  - `ISOTP.firstFrame(to target: UInt8, payload: [UInt8]) -> [UInt8]`: payload of 7 to 4095 bytes (precondition); `[target, 0x10 | length >> 8, length & 0xFF]` and the first 5 payload bytes.
  - `ISOTP.consecutiveFrames(to target: UInt8, payload: [UInt8]) -> [[UInt8]]`: the payload after its first 5 bytes, 6 bytes per frame, each `[target, 0x20 | sequence]` padded with `0x00` to 8; the sequence starts at 1 and goes from `F` back to `0`.
  - `ISOTP.FlowControl: Equatable, Sendable` with `status`, `blockSize`, `separationTime` (all `UInt8`), and `ISOTP.flowControl(_ frame: [UInt8]) -> FlowControl?` for a frame as received, address byte first: nil unless it has at least 4 bytes and a PCI of `3`; `status` is the PCI's low nibble.
- Fix `singleFrame`'s doc comment, which says phase 1 never sends a first frame.

- [ ] **Step 1: Write the failing tests**

```swift
private let write13: [UInt8] = [0x2E, 0x30, 0x00] + Array(0x01...0x0A)

@Test func firstFrameCarriesTheLengthAndFiveBytes() {
    #expect(ISOTP.firstFrame(to: 0x56, payload: write13) == [0x56, 0x10, 0x0D, 0x2E, 0x30, 0x00, 0x01, 0x02])
}

@Test func consecutiveFramesCarrySixBytesEachFromSequenceOne() {
    #expect(ISOTP.consecutiveFrames(to: 0x56, payload: write13) == [
        [0x56, 0x21, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
        [0x56, 0x22, 0x09, 0x0A, 0x00, 0x00, 0x00, 0x00]])
}

@Test func sequenceGoesFromFBackToZero() {
    let frames = ISOTP.consecutiveFrames(to: 0x56, payload: [UInt8](repeating: 0xAB, count: 5 + 6 * 17))
    #expect(frames.map { $0[1] } == Array(0x21...0x2F) + [0x20, 0x21])
}

@Test func readsFlowControl() {
    #expect(ISOTP.flowControl([0xF1, 0x30, 0x08, 0x14, 0, 0, 0, 0])
        == ISOTP.FlowControl(status: 0, blockSize: 8, separationTime: 0x14))
    #expect(ISOTP.flowControl([0xF1, 0x32, 0x00, 0x00])?.status == 2)
    #expect(ISOTP.flowControl([0xF1, 0x03, 0x6E, 0x30]) == nil)
    #expect(ISOTP.flowControl([0xF1, 0x30, 0x00]) == nil)
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `cd Core && swift test --filter ISOTPTests`. Expected: compile errors for the missing functions.

- [ ] **Step 3: Implement the three functions and the struct**

- [ ] **Step 4: Run every Core test**

Run: `cd Core && swift test`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/ISOTP.swift Core/Tests/BMWCodingCoreTests/ISOTPTests.swift
git commit -m "Core: first and consecutive frames for sending, and the flow-control answer read"
```

### Task 3: The write and the voltage in Diag

**Files:**
- Modify: `Core/Sources/BMWCodingCore/Diag.swift`
- Create: `Core/Tests/BMWCodingCoreTests/DiagWriteTests.swift`

**Interfaces:**
- Consumes: Task 2's `firstFrame`, `consecutiveFrames`, `flowControl`.
- Produces, used by Task 4:
  - `func writeDID(_ module: UInt8, _ did: UInt16, _ data: [UInt8]) async throws -> UDSResult`, internal. Selects the module through `select(module:)`, then sends `2E`, the identifier and `data` once. `.positive` is the whole answer (`6E` and the identifier for a good one), `.negative` a refusal that is never `0x78`, `.noResponse` for no final answer, no flow control, a flow control that is not clear to send, or a block's flow control missing.
  - `public func batteryVoltage() async throws -> Double?`: `ATRV` through `resilient`; the first line that reads as a number followed by `V`, such as `12.6V`; nil when none does.

How `writeDID` sends, outside `resilient`:
- A payload of 6 bytes or fewer is one single frame. A longer one is `firstFrame`, then, if the lines answering it hold a flow control from the module that is clear to send, every `consecutiveFrames` frame in turn. With a block size above zero, the lines answering the last frame of each block must hold a new clear-to-send flow control before the next frame goes.
- The frame that completes the request, the single frame or the last consecutive frame, is sent between `expectOK("ATST FF")` and `expectOK("ATST 32")`. `ATST 32` is sent even when the answer is no answer.
- The answer is read from that frame's lines: single frames from the module's response id, `7F 2E 78` skipped, the first other one is the answer.
- No delay is added between consecutive frames. The adapter listens 200 ms after each frame (`ATST 32`), longer than the 127 ms a module may ask. Mark this with a `ponytail:` comment naming the ceiling: a faster send would have to honour the separation time.
- A `LinkError.reconnected` sets `carUnchecked = true`, so the next operation restores the adapter, and is rethrown.
- A flow control that says wait (status 1) ends the exchange like an overflow, which is stricter than the design's "a wait longer than the module's own limits allow". Ruling: the adapter only listens 200 ms after a frame, so a later clear-to-send would be missed anyway; mark it with a `ponytail:` comment, to wait for the next flow control if a module ever sends a wait.

- [ ] **Step 1: Write the failing tests**

In `DiagWriteTests.swift`, a fake module `0x56` answers adapter commands with `OK`. Each test pins `link.sent` from `"ATCRA 656", "ATFCSD 56 30 00 00"` onwards and the result:

1. `shortWriteGoesInOneFrameInsideTheLongListen`: data `[0xAA]`; after the select, sent is `["ATST FF", "56 04 2E 30 00 AA 00 00", "ATST 32"]`; the write frame answered `["656 F1 03 6E 30 00 00 00 00"]`; result `.positive([0x6E, 0x30, 0x00])`.
2. `longWriteWaitsForClearToSendThenSendsEveryFrame`: data `Array(0x01...0x0A)`; sent is `"56 10 0D 2E 30 00 01 02"` (answered `["656 F1 30 00 00 00 00 00 00"]`), `"56 21 03 04 05 06 07 08"` (answered `["NO DATA"]`), `"ATST FF"`, `"56 22 09 0A 00 00 00 00"`, `"ATST 32"`; result `.positive([0x6E, 0x30, 0x00])`.
3. `noClearToSendMeansNoConsecutiveFrame`: the first frame answered with flow-control status 1, then 2, then `NO DATA`, one run each; sent ends with the first frame each time; result `.noResponse`.
4. `blockSizeWaitsForTheNextFlowControl`: flow control `30 01 00` and data of 15 bytes, which needs three consecutive frames; the first is answered with a new clear-to-send and the second with `NO DATA`; the third is never sent; result `.noResponse`.
5. `pendingThenAnswerInTheSameLinesIsTheAnswer`: the completing frame answered `["656 F1 03 7F 2E 78 00 00 00", "656 F1 03 6E 30 00 00 00 00"]`; result `.positive([0x6E, 0x30, 0x00])`.
6. `aLonePendingIsNoAnswerAndNothingIsSentAgain`: answered `["656 F1 03 7F 2E 78 00 00 00"]`; the write frame appears once; the last command is `"ATST 32"`; result `.noResponse`.
7. `aRefusalIsItsCode`: answered `["656 F1 03 7F 2E 33 00 00 00"]`; result `.negative(0x33)`.
8. `aDropDuringTheWriteIsRethrownAndTheNextOperationRestores`: `dropAfter` cuts the write frame; `writeDID` throws `LinkError.reconnected`; the write frame appears once; a `readDID` after it sends `"ATZ"` before its read.
9. `batteryVoltageReadsATRV`: `["12.6V"]` gives `12.6`, `["11.9V"]` gives `11.9`, `["?"]` gives nil.

- [ ] **Step 2: Run them and see them fail**

Run: `cd Core && swift test --filter DiagWriteTests`. Expected: compile errors for the missing functions.

- [ ] **Step 3: Implement `writeDID` and `batteryVoltage`**

- [ ] **Step 4: Run every Core test**

Run: `cd Core && swift test`. Expected: all pass, the existing `DiagTests` unchanged.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/Diag.swift Core/Tests/BMWCodingCoreTests/DiagWriteTests.swift
git commit -m "Core: a write sent once, in one frame or several, inside a longer listen, and the battery voltage"
```

### Task 4: The write test in Core

**Files:**
- Create: `Core/Sources/BMWCodingCore/WriteTest.swift`
- Modify: `Core/Sources/BMWCodingCore/Backup.swift` (`BackupStore.newest(forVIN:complete:)`)
- Create: `Core/Tests/BMWCodingCoreTests/WriteTestTests.swift`
- Modify: `Core/Tests/BMWCodingCoreTests/BackupTests.swift`

**Interfaces:**
- Consumes: Task 1's coding-file names, Task 3's `writeDID` and `batteryVoltage`, the existing `Coding.read`, `Diag.select`, `enterExtendedSession`, `testerPresent`, `readDID`, `ModuleTable.isSigned`.
- Produces, used by Task 5:

```swift
public extension BackupStore {
    /// The newest backup of the car with this VIN in which the module at `address` is complete; nil when none is.
    func newest(forVIN vin: String, complete address: UInt8) throws -> Backup?
}

public enum WriteTest {
    public static let minimumVoltage = 12.0
    public static func isEligible(_ module: DiscoveredModule, vin: String) -> Bool
    /// A negative answer code in plain words, as "needs security access" for 0x33; "answer 0xNN" for one not named.
    public static func describe(_ code: UInt8) -> String

    public struct Ready: Equatable, Sendable {
        public let address: UInt8
        public let identifiers: [UInt16]          // ascending
        public let data: [UInt16: [UInt8]]        // from the fresh read
        public let bytes: Int
        public let backupDate: Date
        public let voltage: Double
    }
    /// One thing that differs: `what` is "coding files" or an identifier as four hex digits; `now` is
    /// "no answer" for an identifier the module did not give.
    public struct Difference: Equatable, Sendable { public let what: String; public let backup: String; public let now: String }
    public enum Preparation: Equatable, Sendable {
        case ready(Ready), notEligible, noBackup, backupTooOld, changed([Difference]), lowVoltage(Double?)
    }
    public static func prepare(diag: Diag, module: DiscoveredModule, vin: String, reference: Backup?) async throws -> Preparation

    public struct Outcome: Equatable, Sendable {
        public let written: Int                   // identifiers written back and read back identical
        public let total: Int
        public let end: End
        public enum End: Equatable, Sendable {
            case accepted
            case refused(identifier: UInt16, code: UInt8)
            case mismatch(identifier: UInt16, written: [UInt8], readBack: [UInt8])
            case noAnswer(identifier: UInt16)
            case sessionRefused, notEligible
            case lowVoltage(Double?)
        }
    }
    public static func run(diag: Diag, module: DiscoveredModule, vin: String, ready: Ready,
                           progress: @escaping (Int, Int) -> Void) async throws -> Outcome
}
```

What `prepare` does, in order, stopping at the first case that applies: `notEligible`; `noBackup` when the reference is nil, lacks the module, has it partial, or holds coding that does not decode as hex; `backupTooOld` when its entry has no coding files; `changed` with one coding-files `Difference` when they differ from `module.codingFiles`; then `Coding.read` of exactly the reference's identifiers, taking the `found` of a thrown `CodingError` as the read; `changed` with every identifier whose bytes differ or that did not answer; `lowVoltage` under 12.0 V or when unreadable; else `ready`. Nothing it sends is a write.

What `run` does: `notEligible` unless `isEligible` holds and `ready.address == module.address`, before anything is sent; the voltage again; `select`, then `enterExtendedSession`, `sessionRefused` when refused; then for each identifier in order: `Task.checkCancellation()`; `writeDID`, where a positive answer must be `6E` and the identifier, a negative ends `refused` and anything else `noAnswer`; `readDID`, where positive equal bytes call `progress(written, total)` and anything else ends `mismatch` or `noAnswer`. TesterPresent goes before any request that comes more than two seconds after the last one, as in `Coding.read`; an internal `run(..., now:)` takes the clock for tests.

- [ ] **Step 1: Write the failing tests**

In `WriteTestTests.swift`, a fake i4 module `0x56` (`codingFiles: ["CAFD_00001D92_006_050_050"]`, VIN `WBY73AW04RFFAKE19`) answers `ATRV` with `12.6V`, `22 30 00` with `AA BB`, `10 03` positively, `3E 00` positively and the write with `6E 30 00`. A reference backup holds `["3000": "AABB"]` and the same coding files, complete.

1. `eligibleOnlyForThePinnedModulesOnTheI4`: true for `0x56` with `CAFD_00001D92_…` and for `0x78` with `CAFD_000051C9_…`; false for `0x56` with another coding file, for another VIN prefix, for `0x40` with the roof file, and for `0x01`.
2. `prepareIsReadyWhenTheCarAgrees`: `.ready` with identifiers `[0x3000]`, 2 bytes, voltage `12.6`, the reference's date.
3. `prepareStopsOnADifferenceAndSendsNoWrite`: the car answers `AA CC`; `.changed([Difference(what: "3000", backup: "AABB", now: "AACC")])`; no sent line contains ` 2E `.
4. `prepareStopsOnAMissingIdentifier`: the car gives nothing for `3000`; `now` is `"no answer"`.
5. `prepareStopsWithoutAUsableBackup`: nil reference and a partial entry give `.noBackup`; empty coding files give `.backupTooOld`; other coding files give `.changed` with `what: "coding files"`.
6. `prepareStopsUnderTwelveVolts`: `11.8V` gives `.lowVoltage(11.8)`; `?` gives `.lowVoltage(nil)`.
7. `runWritesEachIdentifierOnceThenReadsItBack`: `Outcome(written: 1, total: 1, end: .accepted)`; the sent order is `ATRV`, the select, `10 03`, `ATST FF`, the write, `ATST 32`, the read.
8. `runStopsAtTheFirstRefusal`: two identifiers, the first write answered `7F 2E 33`; `.refused(identifier: 0x3000, code: 0x33)`; the second identifier is never written.
9. `runStopsOnAReadBackThatDiffers`: `.mismatch(identifier: 0x3000, written: [0xAA, 0xBB], readBack: [0xAA, 0xCC])`.
10. `runSendsNothingForAnIneligibleModule`: `0x40` and a module with another coding file both give `.notEligible`, and `link.sent` stays empty.
11. `runHoldsTheSessionWithTesterPresent`: with a clock that moves three seconds per request, `3E 00` goes before the read-back.
12. `describeNamesTheCommonCodes`: `0x33` is "needs security access", `0x22` "conditions not correct", `0x31` "identifier out of range", `0x7E` "answer 0x7E".

In `BackupTests.swift`: `newestSkipsBackupsWhereTheModuleIsNotComplete`, with three backups in three different minutes, the newest partial for the module: `newest(forVIN:complete:)` returns the middle one.

- [ ] **Step 2: Run them and see them fail**

Run: `cd Core && swift test --filter WriteTestTests`. Expected: compile errors.

- [ ] **Step 3: Implement `newest(forVIN:complete:)` and `WriteTest`**

`describe` names at least 0x11, 0x12, 0x13, 0x21, 0x22, 0x24, 0x31, 0x33, 0x72 and 0x7F.

- [ ] **Step 4: Run every Core test**

Run: `cd Core && swift test`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/WriteTest.swift Core/Sources/BMWCodingCore/Backup.swift Core/Tests/BMWCodingCoreTests/WriteTestTests.swift Core/Tests/BMWCodingCoreTests/BackupTests.swift
git commit -m "Core: the write test, a module's own coding written back unchanged and read back, on the two pinned modules only"
```

### Task 5: The Write test section

**Files:**
- Modify: `App/Flow.swift`
- Modify: `App/ModuleDetailView.swift`

**Interfaces:**
- Consumes: Task 4's `WriteTest`, `BackupStore.newest(forVIN:complete:)`.
- Produces in `Flow`: `writeTestReady: WriteTest.Ready?`, which shows the confirmation while set; `writeTestProgress`, the done and total counts while a run writes; `writeTestResults: [UInt8: WriteTestResult]`, for the session; `prepareWriteTest(_ module: DiscoveredModule) async`; `confirmWriteTest() async`; `cancelWriteTest()`; `stopWriteTest()`. `WriteTestResult` holds a non-ready `Preparation`, an `Outcome`, or a stop with the counts and why.

Behaviour:
- `prepareWriteTest` and `confirmWriteTest` follow `readFaults()`: they guard on `diag`, `vin` and `!gaveUp` (else "Not connected") and on `!busy` (else "Still working"), and hold `busy` while they talk to the car. `busy` is released while the confirmation waits.
- `confirmWriteTest` runs in a task kept for `stopWriteTest()`, inside `keepingAwake("Writing back a module's coding")`. A `CancellationError` is a stop after the last `progress` count. A link error goes through `explain(_:)` into the stop's why.
- `activity` gains, after the backup case: `Write test · identifier \(done + 1) of \(total) · \(name)`, the module's description as the name.
- `forgetCar()` clears `writeTestReady` and `writeTestResults`.

Screen, at the bottom of the module detail's `Form`, only when `WriteTest.isEligible(module, vin:)`:
- Header `Write test`. Text: "Writes this module's coding back unchanged to see whether it accepts a write. Nothing on the car changes."
- The reference backup is looked up in the screen's existing `.task(id:)`, as its coding data is, never in `body`.
- A `Write test` button, quiet like the screen's other buttons. Disabled while busy, not connected, or when `newest(forVIN:complete:)` finds no backup; the line under it then says "Still working", "Not connected" or "Back up the car first".
- The confirmation: title `Write test on \(name)?`; message "Writes \(n) identifiers, \(bytes) bytes, back unchanged. Checked against the backup of \(date, abbreviated date and short time). Battery \(voltage, one decimal) V. Park with the ignition on."; buttons `Write test` and Cancel.
- While writing: `ProgressLine(value: done, total: total, label: "Writing back identifier \(done + 1) of \(total)", stop: stopWriteTest)`.
- Results, in `.vyn(.footnote)` lines like the screen's others:
  - accepted: "Accepted · \(n) identifiers written back and read back identical", in `vynGreen`.
  - refused: "Refused at \(id) · \(describe(code)) (0x\(code))".
  - mismatch, in `vynRed`: "Read back differently at \(id)", then "Written \(hex)" and "Read back \(hex)" in mono, then "Read this module's fault codes before doing anything else."
  - no answer: "Stopped at \(id) after \(written) of \(total) · no answer".
  - session refused: "Refused the extended session".
  - low voltage: "Battery at \(v) V, under 12.0 V", or "Could not read the battery voltage".
  - changed: "Changed since the backup", then one mono line per difference, `\(what) · backup \(backup) · now \(now)`.
  - no backup: "Back up the car first". Too old: "The backup was made before coding files could be read. Back up the car again."
  - stopped: "Stopped after \(written) of \(total)", with the why when there is one.

- [ ] **Step 1: Implement the Flow state and actions**
- [ ] **Step 2: Implement the section**
- [ ] **Step 3: Build both targets**

Run the Mac and iOS builds from Commands. Expected: both succeed with no warnings.

- [ ] **Step 4: Run every Core test**

Run: `cd Core && swift test`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add App/Flow.swift App/ModuleDetailView.swift
git commit -m "App: the Write test section on the roof and climate modules, with its confirmation, progress, Stop and result"
```

### Task 6: Final check

- [ ] **Step 1: Wire audit**

Run: `grep -rnE '0x2E|"2E"|0x11, |0x27|0x31, ' Core/Sources App`. Expected: a `2E` request is built only in `Diag.writeDID`, and nothing builds `0x11`, `0x27` or `0x31` requests.

- [ ] **Step 2: Full test run and both builds**

Expected: all Core tests pass, both builds succeed with no warnings.

- [ ] **Step 3: Screens**

With a temporary preview hook that is never committed, capture the section on the iPhone simulator: available, unavailable without a backup, the confirmation, writing, accepted, refused, mismatch and changed.
