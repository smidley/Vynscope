# App Sections and Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the five-step wizard with four tabs, Car, Diagnostics, Programming and Settings, add a plain fault-code screen with the mechanic beside it, and make every wait say what it is doing in the app's own idiom.

**Architecture:** Core gains only what the fault-code screen needs: a status-chip rule, a freshness rule and a text summary on `HealthCheck`, each pure and tested; the health check's progress strings gain a count. The app's `Flow` loses its step machine and gains the selected tab, the last fault read and a description of what runs; one `TabView` with the sidebar-adaptable style holds one `NavigationStack` per section; a `ConnectionLine` under every screen's title shows the car's state, the running work and the flow's error; `PulseMark`, `ProgressLine` and `SkeletonRows` are the loading views every screen shares. Operations keep running across tab switches.

**Tech Stack:** Swift 6, `defaultIsolation(MainActor.self)` in package and app, Swift Testing, SwiftUI on iOS 26 / macOS 26 (`TabView` with `.tabViewStyle(.sidebarAdaptable)` and `Tab(_:systemImage:value:)`), xcodegen (the app target's sources are the `App` folder, so new files need no project edit).

**Spec:** `docs/superpowers/specs/2026-10-30-app-sections-design.md`

## Global Constraints

- Nothing new reaches the car: the fault read is `Mechanic.healthCheck`, unchanged on the wire; the chip is computed from bytes already read; no screen has a clear or reset button. The allowed list stays adapter setup, `0x22`, `0x19 0x02` (mask FF), `0x3E`, `0x10 0x03` and standard OBD modes 01/03/07/09 on `7DF`.
- Core changes are Task 1 only. The link, the restoration, the clients, the conversations and the store are untouched.
- A scan, a backup or a mechanic turn is never stopped by navigation; only its own Stop or Cancel ends it.
- Settings and the Log are reachable from every tab.
- The theme as built: `Color.vynIvory/.vynPaper/.vynInk/.vynMuted/.vynLine/.vynGreen/.vynOrange/.vynOrangeDark`, `Font.vyn(_:weight:)`, `Font.vynMono(_:weight:)`. SDK 27's `@State` rule: declared with its initial value, never assigned in an init.
- Both targets build with no warnings after every task (the AppIntents notice aside); the package suite stays green (321 today).
- No API key, token, authorization URL or car data appears in any new log line; the views add no log lines.
- User-facing strings exactly as written in the spec and here.

## Review Focus

- Back up pressed with no module known, reached directly: it must scan first and never write a zero-module file. Pinned in Task 4's flow (the guard after the scan) and Task 6's manual check; `BackupRunner` is not changed.
- Ask the mechanic with a fresh read and a saved conversation: the codes must reach the model as one owner message, never twice. Pinned by Task 1's `faultSummary` tests and Task 3's `handedReadAt`.
- A fault read of one car must never be reused for another: `Flow.forgetCar()` clears the report. Pinned in Task 3.
- A fault status byte with several bits set (`2F`): the chip must be active, not pending or stored. Pinned in Task 1 (`chipReadsTheStatusBitsInOrder`).
- Reduced motion: the pulse and the shimmer must hold still. Pinned in Task 5 by the environment check; checked in Task 6 with the simulator setting.

---

### Task 1: The fault report rules in Core

**Files:**
- Create: `Core/Sources/BMWCodingCore/FaultReport.swift`
- Modify: `Core/Sources/BMWCodingCore/Mechanic.swift:187` (the per-module progress string only)
- Modify: `Core/Tests/BMWCodingCoreTests/MechanicTests.swift:204` (the expected progress strings)
- Test: `Core/Tests/BMWCodingCoreTests/FaultReportTests.swift`

**Interfaces:**
- Produces:

```swift
/// How a fault reads to the owner, from the ISO 14229 status byte the module returned.
public enum FaultChip: String, Sendable, CaseIterable {
    case active, pending, stored, old
    /// `statusHex` as `HealthCheck.Fault.status` holds it, two hex digits: test-failed (bit 0) is active; else pending
    /// (bit 2) is pending; else confirmed (bit 3) is stored; else old. `nil` when the text is not a byte.
    public static func chip(forStatus statusHex: String) -> FaultChip?
}

extension HealthCheck {
    /// Whether the read is recent enough for the mechanic to reuse: `readAt` within `maxAge` seconds of `now`.
    /// The ten minutes are the knob the design names.
    public func isFresh(at now: Date, maxAge: TimeInterval = 600) -> Bool
    /// The read as lines the owner can send the mechanic. "I just read the fault codes:" then one line per module in
    /// order, "<label>: <code> <chip>, <code> <chip>" / "<label>: no faults" / "<label>: <faultRead>", where the label is
    /// "<name> (<address>)" or "0x<address>" without a name; then "OBD stored: <codes>" and "OBD pending: <codes>" when
    /// there are any (codes comma-separated, controllers in sorted order); or the one line "no module answered" when
    /// `nothingAnswered`.
    public var faultSummary: String
}
```

- `Mechanic.healthCheck(progress:)` reports "Reading fault codes · <n> of <m> · <name>" per module (today's "Reading fault codes from <name> …" gains the count; `<name>` is `name(of:)` as today) and keeps "Reading standard OBD codes …" and "Reading standard OBD values …".

- [ ] **Step 1: Write the failing tests**

```swift
@Test func chipReadsTheStatusBitsInOrder() {
    #expect(FaultChip.chip(forStatus: "2F") == .active)   // bits 0, 1, 2, 3, 5: test-failed wins
    #expect(FaultChip.chip(forStatus: "04") == .pending)
    #expect(FaultChip.chip(forStatus: "0C") == .pending)  // pending beats confirmed
    #expect(FaultChip.chip(forStatus: "08") == .stored)
    #expect(FaultChip.chip(forStatus: "28") == .stored)
    #expect(FaultChip.chip(forStatus: "20") == .old)
    #expect(FaultChip.chip(forStatus: "00") == .old)
    #expect(FaultChip.chip(forStatus: "zz") == nil)
}

@Test func aReadIsFreshForTenMinutes() {
    let now = try! Date("2026-10-30T12:10:00Z", strategy: .iso8601)
    #expect(report(readAt: "2026-10-30T12:05:00Z").isFresh(at: now))
    #expect(report(readAt: "2026-10-30T12:00:00Z").isFresh(at: now))        // 600 s exactly
    #expect(!report(readAt: "2026-10-30T11:59:59Z").isFresh(at: now))
    #expect(!report(readAt: "not a date").isFresh(at: now))
    #expect(report(readAt: "2026-10-30T12:05:00Z").isFresh(at: now, maxAge: 60) == false)
}

@Test func theSummaryNamesEveryModuleAndTheOBDCodes() {
    // modules: DME ("12") faults [801E2B "2F", 930BD1 "04"]; BDC_BODY3 ("40") faults []; no name ("60") faultRead "no answer";
    // obd: storedCodes ["7E8": ["P0A80"]], pendingCodes [:]
    #expect(check.faultSummary == """
        I just read the fault codes:
        DME (12): 801E2B active, 930BD1 pending
        BDC_BODY3 (40): no faults
        0x60: no answer
        OBD stored: P0A80
        """)
}

@Test func aSummaryWhereNothingAnsweredSaysSo() {
    // every module faultRead "no answer", obd nil
    #expect(check.faultSummary == "I just read the fault codes:\nno module answered")
}
```

`report(readAt:)` and the checks are built with `HealthCheck`'s memberwise initialiser as `MechanicTests.aCheckWhereNothingAnsweredSaysSo` does (`adapter: .init(model: "", firmware: "")`, `chassis: nil`, `obdError: nil`, `backup: nil`); `HealthCheck.ModuleHealth` likewise with `codingFiles: []`. In `MechanicTests.healthCheckReadsEveryModuleThenStandardOBD` change the expected `steps` to `["Reading fault codes · 1 of 3 · ACSM_5", "Reading fault codes · 2 of 3 · BDC_BODY3", "Reading fault codes · 3 of 3 · FZD__35", "Reading standard OBD codes …", "Reading standard OBD values …"]`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter "FaultReportTests|healthCheckReadsEveryModuleThenStandardOBD"`
Expected: the new file fails to compile (`FaultChip`, `isFresh`, `faultSummary` undefined); the progress expectation fails on the old strings.

- [ ] **Step 3: Implement**

`FaultChip.chip(forStatus:)`: `UInt8(statusHex, radix: 16)`, then bits 0, 2, 3 in that order. `isFresh(at:maxAge:)`: `try? Date(readAt, strategy: .iso8601)` (the format `Mechanic` writes with `Date.now.formatted(.iso8601)`), false when it does not parse, else `now.timeIntervalSince(date) <= maxAge`. `faultSummary`: lines joined with "\n", no trailing newline; a fault's chip word is `FaultChip.chip(forStatus:)?.rawValue ?? "status <hex>"`. In `Mechanic.healthCheck` enumerate `car.modules` for the count.

- [ ] **Step 4: Run the tests to verify they pass, and the suite**

Run: `cd Core && swift test`
Expected: all pass (321 + 4).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/FaultReport.swift Core/Sources/BMWCodingCore/Mechanic.swift Core/Tests/BMWCodingCoreTests/FaultReportTests.swift Core/Tests/BMWCodingCoreTests/MechanicTests.swift
git commit -m "Core: the fault chip, the freshness rule and the owner's summary of a fault read; the health check counts its progress"
```

---

### Task 2: Tabs, the connection line, the Car tab and the Settings tab

**Files:**
- Modify: `App/VynscopeApp.swift` (`FlowView` and `StepIndicator` become `RootView`)
- Modify: `App/Flow.swift` (remove `Step`, `step`, `canGoNext`, `next()`, `back()`; add `tab`, `activity`; `connect()` reads the car)
- Create: `App/ConnectionLine.swift`
- Create: `App/CarTab.swift` (from `ConnectStep.swift` and `CarStep.swift`, which are deleted; `NicknameField` moves with it)
- Modify: `App/AISettingsView.swift` (a tab body, not a sheet)
- Modify: `App/AIFlow.swift:259` (`flow.step == .ai` becomes `mechanicVisible`; nothing else)
- Modify: `App/ModulesStep.swift`, `App/ModuleDetailView.swift`, `App/AIStep.swift` (the `.connectionLine()` modifier only)

**Interfaces:**
- Produces: `enum AppTab: Hashable { case car, diagnostics, programming, settings }`; `Flow.tab: AppTab` (starts `.car`; replaces every `step = .connect`); `Flow.activity: String?` (what runs now, see Step 2); `AIFlow.mechanicVisible = false` (the Mechanic screen sets it in Task 3; `switchProvider` runs its health check only when it is true); `ConnectionLine` and `extension View { func connectionLine() -> some View }` (a `safeAreaInset(edge: .top, spacing: 0)` holding the line; every screen but the Car tab applies it, pushed screens included).

- [ ] **Step 1: The root**

`RootView` replaces `FlowView` and `StepIndicator`: `@Bindable var flow` as today, `TabView(selection: $flow.tab)` with `.tabViewStyle(.sidebarAdaptable)` and four tabs: `Tab("Car", systemImage: "car", value: .car) { NavigationStack { CarTab() } }`, `Tab("Diagnostics", systemImage: "stethoscope", value: .diagnostics) { NavigationStack { AIStep() } }` (Task 3 replaces the root), `Tab("Programming", systemImage: "cpu", value: .programming) { NavigationStack { ModulesStep() } }` (Task 4 reshapes it), `Tab("Settings", systemImage: "gear", value: .settings) { NavigationStack { AISettingsView() } }`. Each stack's root gets `.navigationTitle` ("Car", "Fault codes" for the Diagnostics root even while it is `AIStep`, "Modules", "Settings"), `.toolbarTitleDisplayMode(.inline)`, `.toolbar { ToolbarItem { LogButton() } }` and `.background(Color.vynIvory)`. The iPhone's Log sheet (`flow.showingLog`) moves onto the `TabView`. The `.font`, `.background` and `.tint` on the scene stay; the Mac's Log window stays.

- [ ] **Step 2: The flow**

Delete `Step`, `step`, `canGoNext`, `next()`, `back()`. `reconnect()`'s failure and `explain`'s different-car case set `tab = .car` where they set `step = .connect`; `disconnect()` sets nothing. Add `var tab = AppTab.car` and a computed `var activity: String?`: while `discovering`, "Scanning <XX> of FF · <n> answered" (`String(format: "%02X", scanned)`, `modules.count`); else while `backupTask != nil`, with a `progress`, "Backing up · module <moduleIndex + 1> of <moduleCount>" (Task 3 adds the fault read in front); else nil. `connect()`: factor the body of `readCar()`'s `do` block (the VIN read, `expectedVIN`, the car book lookup, and the `catch` that forgets the car and explains) into `private func readVIN(diag: Diag) async`, called by `readCar()` after its guards and by `connect()` in place of its known-VIN check once `setUp()` succeeded: Connect alone fills the Car section, and a read that fails leaves the adapter connected with the error shown.

- [ ] **Step 3: The connection line**

`ConnectionLine` (reads `Flow` and `AIFlow` from the environment), a `VStack(alignment: .leading, spacing: 2)` in `.vyn(.footnote)`, horizontal padding, 6 points vertical, no background:
- the state row, an `HStack`: when `flow.reconnecting`, "Reconnecting…" in `vynOrangeDark`; else when `flow.link.warning` is set, that text in `vynOrangeDark`; else when `flow.diag == nil`, "Not connected" in `vynMuted` and a borderless `Button(flow.link.state is .failed ? "Reconnect" : "Connect") { flow.tab = .car }`; else "Connected · <nickname, or the VIN's last four> · <n> modules" (the modules part only when `flow.modules` is not empty) in `vynMuted`;
- the activity row, when `flow.activity` is set or `ai.phase` is `.checking`/`.answering`: a `ProgressView()` (Task 5 swaps in the mark) and the text, `flow.activity` first, else the check's step for `.checking`, else "The mechanic is thinking";
- the error row, when `flow.error` is set: the text in `.red`.
The modifier: `extension View { func connectionLine() -> some View { safeAreaInset(edge: .top, spacing: 0) { ConnectionLine() } } }`. Apply it to `AIStep`, `ModulesStep`, `ModuleDetailView` and `AISettingsView`'s bodies (Tasks 3 and 4 apply it to the screens they create).

- [ ] **Step 4: The Car tab**

`CarTab`: a `Form` (grouped, ivory, as both steps are) with, in order: when `flow.error` is set, its text in `.red` as the first section; the Adapter section as `ConnectStep` has it (state, warning, reconnect count, model, firmware, device, device firmware); the buttons section: Connect, and when `flow.diag == nil && flow.vin != nil` (the adapter was dropped after a give-up or by `explain` while a car is known) a line in `.red` with the reason (`flow.link.state`'s `.failed` message, else "The adapter needs to be set up again.") and `Button("Reconnect")` running `flow.reconnect()` then `if flow.diag != nil { ai.error = nil }`, disabled while `flow.busy || flow.reconnecting`; Disconnect and Forget adapter with their footer as today; then `CarStep`'s sections: Read with its ignition footer, the VIN section with the nickname and `NicknameField`, "Also on file". The launch-time auto-connect `.task` with its `.off` guard moves here. `.navigationTitle("Car")`; no connection line. Delete `ConnectStep.swift` and `CarStep.swift`.

- [ ] **Step 5: The Settings tab**

`AISettingsView` drops its own `NavigationStack`, its `.navigationTitle` (the root sets it), its Done button and the `dismiss` environment; the welcome and sign-in sheets and the model-list `.task(id:)` stay; `.connectionLine()` on its form. Any other `AISettingsView()` sheet presentation outside `AIStep` (grep for it) goes; `AIStep`'s stays until Task 3 deletes the file.

- [ ] **Step 6: Build both targets and run the suite**

Run: `make project && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build 2>&1 | grep -E "error:|warning:"; xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet build 2>&1 | grep -E "error:|warning:"; cd Core && swift test 2>&1 | tail -1`
Expected: nothing from either build; the suite green.

- [ ] **Step 7: Commit**

```bash
git add -A App
git commit -m "App: four tabs with a connection line, the Car tab in place of Connect and Car, Settings as a tab; the step machine goes"
```

---

### Task 3: Diagnostics: the fault-code screen and the mechanic beside it

**Files:**
- Create: `App/FaultCodesView.swift`
- Create: `App/MechanicView.swift` (from `AIStep.swift`, which is deleted)
- Modify: `App/VynscopeApp.swift` (the Diagnostics root becomes `FaultCodesView`)
- Modify: `App/Flow.swift` (`faultReport`, `faultReadAt`, `readingFaults`, `readFaults()`, `scan(diag:vin:)`, `connectedCar()`, `forgetCar()`)
- Modify: `App/AIFlow.swift` (`checkAndSummarize` reuses a fresh report; `handFaults()`; `handedReadAt`; `connectedCar` moves to `Flow`)

**Interfaces:**
- Consumes: `FaultChip`, `HealthCheck.isFresh(at:)`, `HealthCheck.faultSummary` (Task 1); `Mechanic.healthCheck(progress:)`; `Flow.activity` (Task 2).
- Produces: `Flow.faultReport: HealthCheck?`, `Flow.faultReadAt: Date?` (set together; `forgetCar()` clears both); `Flow.readingFaults: String?` (the progress text while a read runs; `activity` returns it first); `func readFaults() async`; `private func scan(diag: Diag, vin: String) async throws` (the address walk from `discover()`, which `discover()`, `readFaults()` and Task 4's `backup()` call: sets `discovering`, `scanned`, `modules` as today, each address in its own child task, `discovering = false` in a `defer`; a cancelled walk empties `modules` and throws `CancellationError`, which `discover()` swallows as today and the others report); `func connectedCar() -> (diag: Diag, car: MechanicCar)?` (moved from `AIFlow`, same body); `AIFlow.handFaults() async` (Step 3); `AIFlow.handedReadAt: Date?`.

- [ ] **Step 1: The fault-code screen**

`FaultCodesView` (`.connectionLine()`, ivory, `.navigationTitle("Fault codes")`): a `List`. First: `Button(flow.faultReport == nil ? "Read fault codes" : "Read again") { Task { await flow.readFaults() } }` disabled while `flow.busy`; while `flow.readingFaults` is set, a row with `ProgressView()` and that text (Task 5 swaps in the mark). With a report: one `Section` per module in report order, header `name.map { "\($0) · \(address)" } ?? "0x\(address)"`; a row per fault, an `HStack` of the code in `.vynMono(.body)`, the chip, and the status hex in `.vynMono(.caption)` `vynMuted`; a module whose `faults == []` shows "No faults" in `vynMuted`; one whose `faults == nil` shows its `faultRead` in `vynMuted`. Then a section "OBD" when `obd` has codes: a row per stored code (chip stored) and per pending code (chip pending), the code in mono. The last section's footer: "Read at <faultReadAt, .dateTime.hour().minute()>". With no report and no read running: one footnote in `vynMuted`, "Reads every module's fault memory and the standard codes. Nothing is cleared." The chip: `Text(chip.rawValue).font(.vyn(.caption, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1)` in a capsule: active `.red` with `vynPaper` text, pending `vynOrange` with `vynPaper` text, stored `vynInk` with `vynPaper` text, old `vynLine` with `vynMuted` text; a status that is not a byte shows no chip. Toolbar: `NavigationLink("Ask the mechanic") { MechanicView() }`.

- [ ] **Step 2: The mechanic screen**

`MechanicView` is `AIStep`'s body (`.navigationTitle("Mechanic")`, `.connectionLine()`) with: no gear button, no Settings sheet (the sign-in notice's `Button("Settings")` becomes `Button("Settings") { flow.tab = .settings }`); no `.onDisappear { ai.stop() }`; `.task { ai.mechanicVisible = true; await ai.enter(); await ai.handFaults() }` and `.onDisappear { ai.mechanicVisible = false }`; the "Not connected" form, the checking form, the "Run health check" form and the chat as today; New conversation and its dialog as today. Delete `AIStep.swift`; the Diagnostics root in `RootView` becomes `FaultCodesView()`.

- [ ] **Step 3: The flow and the AI flow**

`Flow.readFaults()`: `guard let diag, let vin else { error = "Not connected"; return }`, `guard !busy else { error = "Still working"; return }`, `busy = true` with a `defer`, `error = nil`; when `modules.isEmpty`, `try await scan(diag: diag, vin: vin)` first and `guard !modules.isEmpty else { error = "No module answered the scan"; return }`; then `guard case let (diag, car)? = connectedCar()`, `readingFaults = "Reading fault codes …"`, `faultReport = try await Mechanic(diag: diag, car: car, log: log).healthCheck { readingFaults = $0 }`, `faultReadAt = .now`; `readingFaults = nil` in a `defer`; a `CancellationError` sets `error = "Cancelled"`, any other error goes through `explain`. `AIFlow.checkAndSummarize()`: `let check: HealthCheck; if let report = flow.faultReport, report.isFresh(at: .now) { check = report } else { check = try await mechanic.healthCheck { phase = .checking($0) }; flow.faultReport = check; flow.faultReadAt = .now }`, and once the conversation is saved, `handedReadAt = flow.faultReadAt` (the context carries that read). `handFaults()`: `guard phase == .ready, conversation != nil, let report = flow.faultReport, report.isFresh(at: .now), flow.faultReadAt != handedReadAt else { return }; handedReadAt = flow.faultReadAt; send(report.faultSummary)`. `switchProvider` and `enter()` are otherwise unchanged. `AIFlow`'s `connectedCar()` call sites use `flow.connectedCar()`.

- [ ] **Step 4: Build both targets and run the suite**

Run: the Task 2 Step 6 command.
Expected: clean builds; suite green.

- [ ] **Step 5: Commit**

```bash
git add -A App
git commit -m "App: Diagnostics opens on a fault-code screen; the mechanic beside it reuses a fresh read or is handed the codes"
```

---

### Task 4: Programming: Modules with Backups, and Back up that scans first

**Files:**
- Rename: `App/ModulesStep.swift` → `App/ModulesView.swift` (`ModulesStep` → `ModulesView`; `ModuleRow` and the `DiscoveredModule` extensions stay in it)
- Rename: `App/BackupStep.swift` → `App/BackupsView.swift` (`BackupStep` → `BackupsView`; `BackupRow` and `sizeText` stay in it)
- Modify: `App/VynscopeApp.swift` (the Programming root becomes `ModulesView`)
- Modify: `App/Flow.swift` (`backup(fullRescan:)`)

**Interfaces:**
- Consumes: `Flow.scan(diag:vin:)` and `Flow.activity` (Tasks 2 and 3).
- Produces: `Flow.backup(fullRescan:)` returns with `error = "Scanning; try again when it is done"` while `discovering`, scans first when `modules` is empty, and ends with `error = "No module answered the scan"` and no file when that scan finds nothing.

- [ ] **Step 1: Modules**

`ModulesView` (`.navigationTitle("Modules")`, `.connectionLine()`): the list without the Scan button row; toolbar `Button(flow.modules.isEmpty ? "Scan" : "Rescan") { Task { await flow.discover() } }` disabled while `flow.busy`; the reconnecting and progress rows as today (Task 5 restyles the progress); while `flow.discovering && flow.modules.isEmpty`, three placeholder rows (`ModuleRow(title: "0x00", description: "module", signed: false)` under `.redacted(reason: .placeholder)`; Task 5 replaces them); the first row, above the modules: `NavigationLink { BackupsView() } label: { LabeledContent("Backups") { Text(latest.map { "last \($0.date.formatted(.dateTime.month(.abbreviated).day()))" } ?? "no backup yet") } }` where `latest` is `@State private var latest: Backup? = nil` loaded by `.task(id: flow.lastBackup) { latest = flow.latestBackup() }` (never read the store in `body`: it re-evaluates per scanned address). The first-scan `.task` and the module-detail destination stay.

- [ ] **Step 2: Backups**

`BackupsView` (`.navigationTitle("Backups")`, `.connectionLine()`) is `BackupStep` with: Back up and Full rescan disabled while `running || flow.discovering`, and while `flow.discovering` the footnote "Scanning; Back up when it is done" in `vynMuted` under them; the first-backup notice only when `firstBackup && !flow.modules.isEmpty`, `firstBackup` re-evaluated by `.task(id: flow.modules.count) { firstBackup = flow.isFirstBackup() }` as well as on `lastBackup`; while a backup's own scan runs (`running && flow.discovering`), the scan's progress row from `ModulesView` above the backup's.

- [ ] **Step 3: The flow**

`Flow.backup(fullRescan:)`, inside `backupTask` after the `backupTask == nil` guard: `guard !discovering else { error = "Scanning; try again when it is done"; return }` replaces `await endDiscovery()`; then the guards as today; after `busy = true`, when `modules.isEmpty`, `try await scan(diag: diag, vin: vin)` inside the existing `do`, then `guard !modules.isEmpty else { error = "No module answered the scan"; return }`; the `CancellationError` catch covers both stages ("Cancelled"). `BackupRunner` is not changed.

- [ ] **Step 4: Build both targets and run the suite**

Run: the Task 2 Step 6 command.
Expected: clean builds; suite green.

- [ ] **Step 5: Commit**

```bash
git add -A App
git commit -m "App: Programming opens on Modules with Backups beside it; Back up scans first and waits for a running scan"
```

---

### Task 5: Loading: the pulse mark, bars with words, skeletons

**Files:**
- Create: `App/Loading.swift` (`PulseMark`, `ProgressLine`, `SkeletonRows`)
- Modify: `App/ConnectionLine.swift`, `App/CarTab.swift`, `App/FaultCodesView.swift`, `App/MechanicView.swift`, `App/ChatView.swift`, `App/ModulesView.swift`, `App/BackupsView.swift`

**Interfaces:**
- Produces: `struct PulseMark: View { var size: CGFloat = 22 }`; `struct ProgressLine: View { let value: Double; let total: Double; let label: String }`; `struct SkeletonRows: View { var count = 3 }`.

- [ ] **Step 1: The three views**

`PulseMark`: two `Shape`s whose `path(in:)` scale a 128×104 box into the rect. The V, filled `vynInk`: `M4 8 H28 Q35 8 39 15 L64 58 L89 15 Q93 8 100 8 H124 L75 88 Q64 106 53 88 Z`. The pulse, one shape of two subpaths stroked `vynOrange`, line width 3.5 (scaled with the box), round joins and caps: `M13 19 L26 24 Q31 26 34 31 L64 82 L94 31 Q97 26 102 24 L115 19` and `M49 49 L55 34 L60 56 L64 20 L68 56 L73 34 L79 49`. The beat: `@State private var drawn = false`, the pulse drawn with `.trim(from: 0, to: drawn ? 1 : 0)`, `.onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { drawn = true } }`; with `@Environment(\.accessibilityReduceMotion)` true, `trim` stays at 1 and nothing animates. Frame `size` wide, `size * 104 / 128` tall. `.accessibilityLabel("Working")`. `ProgressLine`: `VStack(alignment: .leading, spacing: 4)` of the label in `.vyn(.footnote)` `vynMuted` and `ProgressView(value: value, total: total).tint(Color.vynOrange)`. `SkeletonRows`: `count` rows, each a `VStack(alignment: .leading, spacing: 6)` of two capsules in `vynLine`, 14 points tall at 60 % width and 10 points at 35 %, overlaid by a `LinearGradient` of `.clear`, `vynPaper.opacity(0.7)`, `.clear` whose x offset animates from `-width` to `width` over 1.4 s, repeating; still under reduced motion.

- [ ] **Step 2: Apply**

Replace: the connection line's `ProgressView()` with `PulseMark(size: 14)`; in `CarTab`'s Adapter row, when the state is `.scanning`, `.connecting` or `.reconnecting`, `PulseMark(size: 14)` beside the state text; the fault read's row with `HStack { PulseMark(); Text(flow.readingFaults!) }` (the fault read's count is in the words, by the design's ruling that Core's progress stays a string), and while it runs with no report yet, `SkeletonRows()` under it; `MechanicView`'s checking form `ProgressView(step)` with `HStack { PulseMark(); Text(step) }`; `ChatView.LiveTurn`'s `ProgressView("Thinking…")` with `PulseMark()` alone, its `ProgressView("Reconnecting to the adapter…")` with `HStack { PulseMark(); Text("Reconnecting to the adapter…") }`; the scan's progress row (`ModulesView`, and `BackupsView`'s copy) with `ProgressLine(value: Double(flow.scanned), total: 255, label: "Scanning \(String(format: "%02X", flow.scanned)) of FF · \(flow.modules.count) answered so far")`; the placeholder rows with `SkeletonRows()`; the backup's progress section with one `ProgressLine(value: overall(progress), total: 1, label: flow.reconnecting ? "Reconnecting to the adapter…" : "Backing up · module \(progress.moduleIndex + 1) of \(progress.moduleCount) · \(progress.didsDone) of \(progress.didsTotal) identifiers")`.

- [ ] **Step 3: Build both targets and run the suite**

Run: the Task 2 Step 6 command.
Expected: clean builds; suite green.

- [ ] **Step 4: Commit**

```bash
git add -A App
git commit -m "App: the pulse mark, progress lines with words and skeleton rows replace every spinner"
```

---

### Task 6: Verification

**Files:** none.

- [ ] **Step 1: Simulator screenshots** (the controller, as in the theme run: a build into a derived-data path, `simctl install`, a launch, `simctl io screenshot`; any launch switch used to reach a state is a throwaway, never committed): each tab in light and dark on an iPhone simulator, the Fault codes screen in its empty state, the Mac window with the sidebar. Check the connection line on every tab, the mark beating, and reduced motion holding it still (Settings → Accessibility → Motion in the simulator).

- [ ] **Step 2: Scott, in the car**
  - Connect on the Car tab; the car reads by itself; switch to Diagnostics: the line reads "Connected · <car> · n modules" once a scan has run.
  - Read fault codes with the ignition on: the groups and chips; the time in the footer. Ask the mechanic: with no conversation yet, the summary arrives without a second read (the log shows one fault read); with a conversation already saved, the owner message with the codes appears and is answered; Back and Ask again within ten minutes sends nothing twice.
  - Switch tabs during a mechanic turn and during a scan: both keep running; the connection line shows them.
  - Programming: Backups with no module known: the scan runs first, then the backup; Back up during a scan is disabled with its note.
  - Settings from any tab; the Log from any tab.
