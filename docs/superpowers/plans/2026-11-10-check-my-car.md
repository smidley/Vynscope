# Check my car Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One button on the first screen connects, reads the car and its fault codes and answers in a sentence, and an Advanced switch hides everything that needs car knowledge.

**Architecture:** Core gains two small tested values: the verdict of a fault read with the plain problem lines, and the file that remembers each car's systems. The app's flow learns to walk only the remembered systems and to know when its module list came from a full walk. A check action chains what Connect, Read, the scan and the fault read do today and drives a card on top of the Car tab. An Advanced value in the flow hides the Programming tab, the log, raw bytes and the adapter's controls.

**Tech Stack:** Swift 6 (strict concurrency, `defaultIsolation(MainActor.self)`), Swift Testing for Core, SwiftUI for iOS and macOS 26, xcodegen. The app target has no tests.

**Spec:** `docs/superpowers/specs/2026-11-10-check-my-car-design.md`. Read it before starting any task. The mockup it names is `.superpowers/brainstorm/30196-1794329905/content/check-my-car.html`.

## Global Constraints

- Nothing new is sent to the car. The check calls only what exists: `BLELink.connect`, `Diag.setUp`, `VIN.read`, `Discovery.modules`, `Mechanic.healthCheck`. The wire allow-list does not change.
- A backup never runs from a remembered list: it walks every address first unless the module list came from a full walk.
- The remembered systems of a car are replaced only by a full walk that ran to its end and found at least one module.
- Copy is used exactly as written in this plan and the spec. Counts are inflected with `^[\(n) word](inflect: true)`.
- One filled action per screen, with `.primaryAction()`; every other button is quiet (`.quietButtons()` on the form). Errors and the active chip use `Color.vynRed`, a clean verdict `Color.vynGreen`.
- `@State` properties are declared with an initial value and never assigned in an `init` (SDK 27). Nothing reads a file in a view's `body`.
- Tests use `FakeLink` or plain values only and never touch the car, Anthropic or OpenAI. Test VINs use `WBY73AW04RFFAKE19`. The real VIN, car logs and backup files are never committed.
- Doc comments follow the codebase: full sentences on what and why, wrapped at 120 columns; `ponytail:` comments mark a deliberate ceiling and its upgrade path.
- One commit per task, subject in the repo's style (`Core: ...`, `App: ...`), ending with a `Co-Authored-By` trailer naming your own model.

## Commands

- All Core tests: `cd Core && swift test`. One suite: `cd Core && swift test --filter CheckVerdictTests`.
- Mac build, not launched: `make project && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build`.
- iOS build: `xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios -quiet build`.
- Never `make mac`: it launches the app.

## Review Focus

1. A green verdict on incomplete data: any system that refused, gave no answer or an unreadable one, a remembered system that stayed silent, a failed standard read, or a car where nothing answered must leave `clean` false. Pinned in Task 1.
2. A stale or emptied memory of a car: an empty list must never replace what was remembered, and a walk that was stopped, failed or found nothing must not save. Pinned in Task 2; the saving rule in Task 3 is checked by reading.
3. A backup after a quick check: `backup` must walk every address first when the list did not come from a full walk. The app has no tests, so the reviewer checks the condition by reading, and Scott checks it in the car.
4. Stop at every step of the check: `busy` and the step are cleared, no problem line is left, and no adapter request is cut in the middle. Checked by reading in Task 4.
5. Advanced switched off while work is running: the switch is disabled while the flow is busy, and a flow on the Programming tab moves to Car. Checked by reading in Task 5.

---

### Task 1: The verdict and the problem lines

**Files:**
- Create: `Core/Sources/BMWCodingCore/CheckVerdict.swift`
- Test: `Core/Tests/BMWCodingCoreTests/CheckVerdictTests.swift`

**Interfaces:**
- Consumes: `HealthCheck`, `FaultChip.chip(forStatus:)`, `HealthCheck.nothingAnswered`, `LinkError`, `DiagError`, `VINError`.
- Produces, used by Task 4:

```swift
public struct CheckVerdict: Equatable, Sendable {
    public let codes: Int              // fault codes: the systems' and the standard ones
    public let systemsWithCodes: Int
    public let active: Int             // codes whose chip is .active
    public let read: Int               // systems whose fault read came back with a list, empty or not
    public let unread: Int             // every other system
    public let rows: [Row]
    public let nothingAnswered: Bool
    /// No codes, every system read, and something answered: the only verdict shown in green.
    public var clean: Bool { get }
    public struct Row: Equatable, Sendable { public let name: String; public let chips: [FaultChip] }
}

public extension HealthCheck {
    /// `silent` is how many remembered systems did not answer the walk before this read.
    func verdict(silent: Int = 0) -> CheckVerdict
}

public enum CheckProblem {
    public static let silentCar = "The car did not answer. Switch the ignition on and try again."
    /// What to do about `error`, in plain words. `connecting` is whether it ended the step that reaches the adapter.
    public static func line(for error: any Error, connecting: Bool) -> String
}
```

The rules of `verdict(silent:)`:
- A module with `faults != nil` is read; any other is unread. `unread` also adds `silent`, and 1 when `obdError != nil`.
- `codes` is every module fault plus every standard stored and pending code. `active` counts the module faults whose chip is `.active`.
- One row per module with at least one fault, in the read's order: the name is its `description`, else its `name`, else `"System 0x" + address`; the chips are those its faults have, each once, in the order active, pending, stored, old. A status that is not a byte has no chip and still counts as a code.
- When `obd` holds any stored or pending code: one last row named `Standard codes`, with `.pending` when any is pending and `.stored` when any is stored, in that order; it adds 1 to `systemsWithCodes`. An `obd` with no codes, or `nil`, adds nothing.
- `nothingAnswered` is the check's own.

The lines of `CheckProblem.line(for:connecting:)`:

| Error | Line |
|---|---|
| `LinkError.adapterError` whose text starts with `Bluetooth is off` | `Bluetooth is off. Switch it on and try again.` |
| `LinkError.adapterError("Bluetooth is not allowed for this app")` | `Vynscope is not allowed to use Bluetooth. Allow it in Settings and try again.` |
| `LinkError.adapterError("This device does not support Bluetooth LE")` | `This device has no Bluetooth LE, which the adapter needs.` |
| any other `LinkError.adapterError`, `connecting` true | `No adapter found. Plug it in, wait for its light and try again.` |
| any other `LinkError.adapterError`, `connecting` false | `The adapter reported a problem. Try again.` |
| `LinkError.timeout` | `The adapter did not answer in time. Try again.` |
| `LinkError.disconnected`, `DiagError.keptDropping` | `The connection to the adapter was lost. Move closer and try again.` |
| `LinkError.reconnected` | `The adapter reconnected. Try again.` |
| `VINError.noVIN`, `DiagError.carSilent` | `CheckProblem.silentCar` |
| `DiagError.differentCar` | `A different car answered. Check again to read it.` |
| anything else | `The check could not finish. Try again.` |

- [ ] **Step 1: Write the failing tests**

In `CheckVerdictTests.swift`, with private helpers `report(modules:obd:)`, `module(_:name:description:faults:faultRead:)` and `obd(stored:pending:)` shaped like those in `FaultReportTests.swift`:

```swift
@Test func cleanWhenEverySystemWasReadAndNoneHasCodes() {
    let verdict = report(modules: [module("01", faults: []), module("56", faults: [])]).verdict()
    #expect(verdict == CheckVerdict(
        codes: 0, systemsWithCodes: 0, active: 0, read: 2, unread: 0, rows: [], nothingAnswered: false))
    #expect(verdict.clean)
}

@Test func countsCodesSystemsAndActiveOnesWithARowPerSystem() {
    let verdict = report(modules: [
        module("56", name: "FZD__35", description: "Roof functions",
               faults: [.init(code: "E1C441", status: "2F"), .init(code: "E1C442", status: "08")]),
        module("78", name: "IHKA_PRO2",
               faults: [.init(code: "801A2B", status: "28"), .init(code: "801A2C", status: "08")]),
        module("29", faults: [.init(code: "D0170A", status: "20")]),
        module("01", faults: []),
    ]).verdict()
    #expect(verdict.codes == 5 && verdict.systemsWithCodes == 3 && verdict.active == 1)
    #expect(verdict.read == 4 && verdict.unread == 0 && !verdict.clean)
    #expect(verdict.rows == [
        .init(name: "Roof functions", chips: [.active, .stored]),
        .init(name: "IHKA_PRO2", chips: [.stored]),
        .init(name: "System 0x29", chips: [.old]),
    ])
}

@Test func unreadAndSilentSystemsBlockTheGreenVerdict() {
    let check = report(modules: [
        module("01", faults: []), module("56", faultRead: "refused (0x11)"),
        module("60", faultRead: "no answer"), module("63", faultRead: "unreadable 5902"),
    ])
    #expect(check.verdict().unread == 3 && !check.verdict().clean)
    let verdict = check.verdict(silent: 2)
    #expect(verdict.read == 1 && verdict.unread == 5 && verdict.codes == 0 && !verdict.clean)
    #expect(!report(modules: [module("01", faults: [])]).verdict(silent: 1).clean)
}

@Test func standardCodesAddARowAndASystemOnlyWhenTheCarReportedSome() {
    let none = report(modules: [module("01", faults: [])], obd: obd()).verdict()
    #expect(none.codes == 0 && none.systemsWithCodes == 0 && none.rows.isEmpty && none.clean)
    let some = report(
        modules: [module("01", faults: [])],
        obd: obd(stored: ["7E8": ["P0A1F"]], pending: ["7E8": ["P0AA6"], "7E9": ["P1E00"]])).verdict()
    #expect(some.codes == 3 && some.systemsWithCodes == 1 && some.active == 0)
    #expect(some.rows == [.init(name: "Standard codes", chips: [.pending, .stored])])
}

@Test func aFailedStandardReadCountsAsUnread() {
    var check = report(modules: [module("01", faults: [])])
    check.obdError = "timeout"
    #expect(check.verdict().unread == 1 && !check.verdict().clean)
}

@Test func nothingAnsweredIsNeverClean() {
    let verdict = report(modules: [module("01", faultRead: "no answer")]).verdict()
    #expect(verdict.nothingAnswered && !verdict.clean)
}

@Test func aStatusThatIsNotAByteHasNoChipAndStillCounts() {
    let verdict = report(modules: [module("56", faults: [.init(code: "E1C441", status: "zz")])]).verdict()
    #expect(verdict.codes == 1 && verdict.rows == [.init(name: "System 0x56", chips: [])])
}
```

And `problemLinesSayWhatToDo`, one `#expect` per row of the table above, with `LinkError.adapterError("Bluetooth is off. Switch it on and reconnect.")` for the first row and `LinkError.adapterError("CAN ERROR")` for both the connecting and the not-connecting rows.

- [ ] **Step 2: Run them and see them fail**

Run: `cd Core && swift test --filter CheckVerdictTests`. Expected: compile errors for the missing types.

- [ ] **Step 3: Implement `CheckVerdict`, `HealthCheck.verdict(silent:)` and `CheckProblem`**

- [ ] **Step 4: Run every Core test**

Run: `cd Core && swift test`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/CheckVerdict.swift Core/Tests/BMWCodingCoreTests/CheckVerdictTests.swift
git commit -m "Core: a fault read's verdict in counts and rows, green only when everything was read, and plain lines for what went wrong"
```

### Task 2: Remembered systems

**Files:**
- Create: `Core/Sources/BMWCodingCore/KnownModules.swift`
- Test: `Core/Tests/BMWCodingCoreTests/KnownModulesTests.swift`

**Interfaces:**
- Produces, used by Task 3. Model it on `RememberedSets` in `Coding.swift` (the same load and save behaviour: empty when the file is missing or cannot be decoded, pretty-printed JSON with sorted keys, written atomically, folders created):

```swift
public struct KnownModules: Codable, Equatable {
    /// The addresses that answered the last full walk of each car, by VIN, ascending.
    public var cars: [String: [UInt8]]
    public static func load(from url: URL) -> KnownModules
    public func save(to url: URL) throws
    /// `nil` when nothing is remembered for the car.
    public func addresses(forVIN vin: String) -> [UInt8]?
    /// Sorted, without duplicates. An empty list changes nothing, so a silent car never erases what was known.
    public mutating func remember(_ addresses: [UInt8], forVIN vin: String)
}
```

- [ ] **Step 1: Write the failing tests**

```swift
private let vin = "WBY73AW04RFFAKE19"

@Test func remembersSortedAndWithoutDuplicates() {
    var known = KnownModules(cars: [:])
    known.remember([0x78, 0x01, 0x56, 0x01], forVIN: vin)
    #expect(known.addresses(forVIN: vin) == [0x01, 0x56, 0x78])
    #expect(known.addresses(forVIN: "WBY73AW04RFFAKE20") == nil)
}

@Test func anEmptyListKeepsWhatWasRemembered() {
    var known = KnownModules(cars: [vin: [0x01]])
    known.remember([], forVIN: vin)
    #expect(known.addresses(forVIN: vin) == [0x01])
}

@Test func savesAndLoadsAndToleratesAMissingOrBrokenFile() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        .appending(path: "known-modules.json")
    #expect(KnownModules.load(from: url) == KnownModules(cars: [:]))
    var known = KnownModules(cars: [:])
    known.remember([0x56, 0x01], forVIN: vin)
    try known.save(to: url)
    #expect(KnownModules.load(from: url) == known)
    try Data("not json".utf8).write(to: url)
    #expect(KnownModules.load(from: url) == KnownModules(cars: [:]))
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `cd Core && swift test --filter KnownModulesTests`. Expected: compile errors.

- [ ] **Step 3: Implement `KnownModules`**

- [ ] **Step 4: Run every Core test**

Run: `cd Core && swift test`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/KnownModules.swift Core/Tests/BMWCodingCoreTests/KnownModulesTests.swift
git commit -m "Core: the systems that answered a car's last full walk, kept by VIN, which an empty walk never erases"
```

### Task 3: The walk of the remembered systems

**Files:**
- Modify: `App/Flow.swift` (`scan`, `discover`, `readFaults`, `backup`, `forgetCar`, `activity`)
- Modify: `App/Loading.swift` (`ScanProgress`)
- Modify: `App/ModulesView.swift`

**Interfaces:**
- Consumes: Task 2's `KnownModules`; the existing `Discovery.modules(diag:vin:addresses:)`.
- Produces in `Flow`, used by Tasks 4 and 5:
  - `var modulesFromFullWalk = false`: whether `modules` came from a walk of every address.
  - `var silentSystems = 0`: the remembered systems that did not answer the last quick walk; 0 after a full walk.
  - `var scanQuick = false` and `var scanTotal = 255`: while a walk runs, whether it covers only the remembered systems, and what `scanned` counts up to.
  - `func discover(full: Bool = false) async -> Bool` (discardable): the Modules screen passes `full: true`.
  - `private func scan(diag: Diag, vin: String, full: Bool) async throws`.

Behaviour:
- `scan` with `full` false walks only the car's remembered addresses when `KnownModules.load(from: file("known-modules.json"))` has some; otherwise it walks every address as today. Each address still runs in a task a stop does not cancel, with the cancellation check between addresses.
- On a quick walk `scanned` is how many addresses are done and `scanTotal` how many there are; on a full walk they are the address and 255, as today.
- A full walk is a walk of every address, whatever `full` was. One that ends without an error and with at least one module sets `modulesFromFullWalk = true` and `silentSystems = 0`, and remembers the modules' addresses for the VIN. A save that fails is logged with `log.note` and otherwise ignored: the file is a cache.
- A quick walk that ends sets `modulesFromFullWalk = false` and `silentSystems` to the remembered addresses that did not answer.
- A walk that is stopped or fails empties the list as today and saves nothing.
- `readFaults()` and `discover()` scan with `full: false`; `ModulesView`'s toolbar button and its first-appearance scan call `discover(full: true)`.
- `backup(fullRescan:)` scans with `full: true` when `modules.isEmpty || !modulesFromFullWalk`. Its `fullRescan` parameter is about identifiers and is unrelated.
- `forgetCar()` resets `modulesFromFullWalk` and `silentSystems`.
- `Flow.activity` and `ScanProgress` say, on a quick walk, `Checking the car's systems · \(scanned + 1) of \(scanTotal)`, with the bar at `scanned` of `scanTotal`; on a full walk they are unchanged.
- `ModulesView` shows, as a muted footnote row above the modules, when the list is not empty, did not come from a full walk and no walk runs: `The systems remembered from the last full scan. Scan looks at every address again.`

- [ ] **Step 1: Implement the flow changes**
- [ ] **Step 2: Implement `ScanProgress` and the Modules note**
- [ ] **Step 3: Build both targets** (Commands). Expected: both succeed with no warnings.
- [ ] **Step 4: Run every Core test.** Expected: all pass.
- [ ] **Step 5: Commit**

```bash
git add App/Flow.swift App/Loading.swift App/ModulesView.swift
git commit -m "App: a walk of the systems a car is remembered to have, for fault reads and health checks; backups and the Modules screen still walk every address"
```

### Task 4: The check and its card

**Files:**
- Modify: `App/Flow.swift` (the check action and its state; `diagnosticsPath`)
- Create: `App/CheckCard.swift`
- Modify: `App/CarTab.swift` (the card as the first section)
- Modify: `App/VynscopeApp.swift`, `App/FaultCodesView.swift` (the Diagnostics stack's path)

**Interfaces:**
- Consumes: Task 1's `CheckVerdict`, `HealthCheck.verdict(silent:)`, `CheckProblem`; Task 3's `scan(diag:vin:full:)`, `silentSystems`, `scanQuick`, `scanTotal`.
- Produces in `Flow`:

```swift
enum CheckStep: Equatable { case connecting, readingCar, findingSystems, readingFaults }
enum DiagnosticsRoute: Hashable { case mechanic }

var checkStep: CheckStep?                       // nil while no check runs
var checkProblem: String?                       // the last check's plain problem line; cleared when a check starts
var diagnosticsPath: [DiagnosticsRoute] = []    // the Diagnostics tab's navigation stack
func checkCar() async
func stopCheck()
```

The check, in order, holding `busy` from start to end inside `keepingAwake("Checking the car")`:
1. `connecting`, when there is no usable adapter (`diag == nil`, a give-up, or a link that is neither ready nor reconnecting by itself): what `connect()` does up to and including the adapter's setup, with its rules for forgetting the car and the saved adapter.
2. `readingCar`, when no VIN is known: what `readVIN` does.
3. `findingSystems`, when no module is listed: `scan(diag:vin:full: false)`. No module answering ends the check with `CheckProblem.silentCar`.
4. `readingFaults`: what `readFaults()` does inside its task, into `faultReport` and `faultReadAt`. A read in which nothing answered ends the check with `CheckProblem.silentCar`.

- A step that throws sets `checkProblem = CheckProblem.line(for: error, connecting: step == .connecting)`, still passes the error through `explain(_:)` for its effects on the adapter and the car, writes the text `explain` returns to the log, and leaves `error` nil: the card says it.
- `Flow.connect()`, `readCar()` and `readFaults()` keep their behaviour; share their bodies with the check, do not copy them.
- Stop: during `connecting`, `stopCheck()` calls `disconnect()`. In every later step it cancels the check's task; the VIN read and the fault read each run in a task the stop does not cancel, as `scan` does per address, and the check tests for cancellation between steps. A stopped check leaves `checkStep` nil, `checkProblem` nil and `busy` false.
- `stopScan()` also stops a running check, so Stop on any screen ends it. `Flow.activity` says `Checking the car` during the check's first two steps; the walk and the fault read already say their own.
- `Explain it` sets `tab = .diagnostics` and `diagnosticsPath = [.mechanic]`; `See the codes` sets `tab = .diagnostics` and `diagnosticsPath = []`. `RootView` binds the Diagnostics stack to `diagnosticsPath`, with `MechanicView` as the destination of `.mechanic`; `FaultCodesView`'s `Ask the mechanic` link becomes a link to that value.

The card, `CheckCard`, the Car tab's first section in both modes:
- Its first line is the car's nickname when one is known.
- **Before**, with no report, no step and no problem: `Check my car` with `.primaryAction()`, then `Plug in the adapter and switch the ignition on. Nothing on the car is changed.` While `UserDefaults.standard.string(forKey: Flow.adapterKey)` is nil, also `The first time, tap within five minutes of plugging the adapter in. Enter 123456 if asked for a PIN.` Both in muted footnote text.
- **Running**: one line per step up to the running one. A finished or skipped step shows a green check mark, hidden from VoiceOver, and its done words; the running one `PulseMark(size: 14)` and its running words:

| Step | Running | Done |
|---|---|---|
| `connecting` | `Connecting to the adapter` | `Adapter connected` |
| `readingCar` | `Reading the car` | `Car recognised · <nickname, or the VIN's last four>` |
| `findingSystems`, full walk | `Looking for the car's systems · <n> found`, with the bar | `^[<n> system](inflect: true) found` |
| `findingSystems`, quick walk | `Checking the car's systems · <i> of <m>`, with the bar | the same done words |
| `readingFaults` | `flow.readingFaults` | |

  Then `Stop`.
- **Answer**, when `faultReport` is set and its verdict is not `nothingAnswered`, from `faultReport.verdict(silent: silentSystems)`:
  - the sentence in headline weight, `Color.vynGreen` when `clean`, else ink: `No fault codes`, or `^[<codes> fault code](inflect: true) in ^[<systemsWithCodes> system](inflect: true)`
  - a muted footnote line joining with ` · ` the parts that apply: `<active> active now`, `^[<read> system](inflect: true) checked`, `<unread> could not be read`, and the time of `faultReadAt`
  - one row per verdict row: the name, then its chips drawn as the fault-code screen draws them. Move that screen's chip drawing into one shared view; do not copy it.
  - `Explain it` with `.primaryAction()` when `codes > 0`; `See the codes`; `Check again`.
- **Problem**, when `checkProblem` is set or the report's verdict is `nothingAnswered` (then `CheckProblem.silentCar`): the line in ink, and `Try again` with `.primaryAction()`. It shows above an earlier answer.
- The buttons are disabled while `busy`, except `Stop`. While something other than a check holds the adapter, the card shows `PulseMark(size: 14)` with `Connecting to the adapter…` when the link is scanning or connecting, as at launch, else with `flow.activity`.

- [ ] **Step 1: Implement the flow's check, its state and the Diagnostics path**
- [ ] **Step 2: Implement `CheckCard` and put it on the Car tab**
- [ ] **Step 3: Build both targets.** Expected: both succeed with no warnings.
- [ ] **Step 4: Run every Core test.** Expected: all pass.
- [ ] **Step 5: Commit**

```bash
git add App/Flow.swift App/CheckCard.swift App/CarTab.swift App/VynscopeApp.swift App/FaultCodesView.swift
git commit -m "App: Check my car, one button on the Car tab that connects, reads the car and its fault codes and answers in a sentence"
```

### Task 5: The Advanced switch

**Files:**
- Modify: `App/Flow.swift`, `App/AISettingsView.swift`, `App/VynscopeApp.swift`, `App/LogView.swift`, `App/CarTab.swift`, `App/FaultCodesView.swift`, and the other screens that place a `LogButton`: `App/MechanicView.swift`, `App/ModuleDetailView.swift`, `App/BackupsView.swift`

**Interfaces:**
- Produces in `Flow`: `var advanced: Bool`, read from the user defaults key `advanced` at launch, false when never set, and written back whenever it changes.

Behaviour:
- Settings ends with a section holding the toggle `Advanced` and the footer `Shows Programming with its modules, backups and write test, the adapter's details, raw status bytes and the log.` The toggle is disabled while `flow.busy`.
- With `advanced` false:
  - the tab view has no Programming tab, on the iPhone and in the Mac's sidebar; a flow whose `tab` is `.programming` when the value turns false moves to `.car`
  - no `Log` button on any screen, and no empty toolbar slot where it was
  - fault rows show no raw status byte
  - the Car tab shows the check card, then the VIN with the nickname field once a car is read; the adapter's section, Connect, Reconnect, Disconnect, Forget adapter, Read, their footers and Also on file are not shown
  - Settings shows the AI provider, its sign-in, Privacy, Conversations and Advanced; the Model, Effort and Prices sections and the Mac's App folder section are not shown
- With `advanced` true everything is as before this task, with the check card on top of the Car tab and the switch at the end of Settings.

- [ ] **Step 1: Implement `Flow.advanced` and the Settings section**
- [ ] **Step 2: Hide what Advanced off hides**
- [ ] **Step 3: Build both targets.** Expected: both succeed with no warnings.
- [ ] **Step 4: Run every Core test.** Expected: all pass.
- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "App: an Advanced switch in Settings; off, the app shows the check, the fault codes, the mechanic and the sign-in, and nothing that needs car knowledge"
```

### Task 6: Final check

- [ ] **Step 1: Nothing new on the wire.** Run: `git diff main --stat -- Core/Sources/BMWCodingCore/Diag.swift Core/Sources/BMWCodingCore/ISOTP.swift Core/Sources/BMWCodingCore/ELM.swift`. Expected: no changes.
- [ ] **Step 2: Full test run and both builds.** Expected: all Core tests pass, both builds succeed with no warnings.
- [ ] **Step 3: Screens.** With a temporary preview hook that is never committed, capture on the iPhone simulator: the card before a check with and without a remembered adapter, each running step, a clean answer, an answer with codes and unread systems, a problem line, Settings with Advanced off and on, the three-tab and four-tab bars, and the Modules note.
