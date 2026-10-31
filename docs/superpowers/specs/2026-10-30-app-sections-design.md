# App sections and navigation — design

Date: 2026-10-30. Owner: Scott. Direction given in the car on 2026-10-29: the app's two jobs, reading fault codes and car programming, become two sections; every screen is reachable directly instead of by stepping Next through all of them; the loading animations look better. Scott asked me to use my judgement on the rest, so every choice below not attributed to him is mine.

## Intent

Today the app is a five-step wizard: Connect, Car, Modules, Backup, AI, with Next and Back. That shape suited the first weeks, when every session was "connect, back the car up". It fights the two things the app now does well: a diagnostic read with a mechanic to explain it, and the module survey and backups that programming rests on. An owner who wants to ask about a warning light should not step through Modules and Backup to get there, and an owner on the Backup screen should be able to glance at the codes without leaving.

## Goals

- Two sections, **Diagnostics** and **Programming**, each with its own screens, after a shared **Car** area that holds the adapter connection and the car's identity (Scott's).
- Every screen one tap away from anywhere; nothing gated behind a Next button (Scott's).
- Loading that says what it is doing and how far along, drawn in the app's own idiom, not the system's grey spinner (Scott's).
- A plain fault-code screen that reads the codes from every module without a model turn, with the mechanic beside it to explain them (decided with Scott on 2026-10-29).
- The same app on the iPhone and the Mac, each in its platform's own navigation idiom.

## Non-goals

- Coding, writing anything to the car, or a "Coding" screen. The Programming section holds the survey and the backups; coding comes later and is not sketched here.
- A fault-code description database. Codes show as the car reports them, with their status; the mechanic explains them.
- Changes to the Core package beyond what the fault-code screen needs (below). The link, the restoration, the clients and the conversations stay as they are.
- A redesign of the chat itself beyond its loading state.

## Anti-goals

- A "Clear codes" button, anywhere, ever. Reading is the app's whole relationship with faults.
- An operation that stops because the owner looked at another tab. A scan, a backup or a mechanic turn keeps running; only its own Stop ends it.
- Settings or the Log reachable from one screen only.
- Hiding the adapter's state. Every section says whether the car is connected, in the same place.

## The frame: tabs

Four tabs: **Car**, **Diagnostics**, **Programming**, **Settings**. On the iPhone a tab bar; on the Mac the same tabs as a sidebar (SwiftUI's sidebar-adaptable tab style gives both from one declaration). The Log keeps its toolbar button on every tab and its own window on the Mac, as today. The step strip, Next, Back and Done go away, and so does the notion of a current step in the flow.

I chose tabs over a home screen of tiles (one extra tap to everything, and the car's state would live on a screen you leave) and over a sidebar-first design (right for the Mac, awkward as the iPhone's first screen). Tabs are the idiom both platforms already teach their users.

### The connection line

Diagnostics, Programming and Settings each show one line under their title, the same on every tab:

- "Connected · i4 eDrive40 · 23 modules" (the nickname, or the VIN's last four when there is none; the module count once a scan has run)
- "Not connected · Connect" where Connect is a button that switches to the Car tab
- "Reconnecting…" during a reconnect, "Weak Bluetooth signal" or "The adapter dropped and reconnected" when the link warns, in the warning color
- while something runs anywhere: what it is and how far, "Scanning 3A of FF", "Backing up · module 7 of 23", "Reading fault codes · DME", "The mechanic is thinking", with the pulse mark beating beside it

The line is the owner's one place to know the car's state and that work is in progress, whatever tab they are on.

## Car

One screen, two sections, replacing the Connect and Car steps.

**Adapter**: the state (Not connected / Scanning… / Connecting… / Connected / Reconnecting… / the failure), the model and firmware, the warning line and "Reconnected N times this session" as built on the Bluetooth branch, and the buttons Connect, Disconnect, Forget adapter, Reconnect (after a give-up, as today). The launch-time auto-connect stays.

**Car**: the VIN in mono, the nickname (a field to give or change it), "Also on file" with the other cars from the car book, and a Read button for a re-read. New: a successful connect reads the car at once, so the owner does not press Read after Connect; Read stays for the ignition-was-off case and shows "Turn the ignition on; there is no need to start driving." as today when nothing answers.

## Diagnostics

A navigation stack whose root is **Fault codes**; the **Mechanic** screen is pushed from it.

### Fault codes

- A **Read fault codes** button (and "Read again" once a read exists). The read is the health check's reading half without the model: every discovered module's fault memory (service 0x19 0x02, mask FF) and the standard OBD requests, with a progress bar "module n of m · <name>". When no module is known yet, the scan runs first with its own progress, as the health check already does.
- The result, grouped by module, each module a section headed by its name or address: one row per code with the code in mono, a status chip, and the raw status byte in muted mono. Standard OBD codes form their own section, "OBD", split stored and pending. A module with no codes shows "No faults" in muted text; a module that refused or did not answer shows that, as the health check records it. The time of the read in the section footer.
- The status chip, from the ISO 14229 status byte the car returns: **active** when test-failed is set (bit 0), **pending** when pending is set (bit 2) and test-failed is not, **stored** when confirmed is set (bit 3) and neither of those, otherwise **old**. Standard OBD codes are **stored** or **pending** by the mode they came from. This is my reading of the status bits; the builder pins it with tests from the byte values and Scott's car confirms it.
- **Ask the mechanic** in the toolbar pushes the Mechanic screen. Nothing on this screen writes to the car; there is no clear button.

### Mechanic

Today's AI step, moved: the health check with its summary as the conversation's first turn, the chat, Try again, the plan states, Stop. Two changes:

- The health check reuses the last fault read when it is less than ten minutes old instead of reading the car again, so Read fault codes then Ask the mechanic costs one read, not two. An older read, or none, reads as today. The ten minutes are a calibration knob.
- A turn keeps running when the owner switches tabs. Stop is the only thing that ends it. Leaving the Mechanic screen no longer stops anything.

The sign-in notice ("Sign in to ChatGPT in Settings…") and the "Not connected" state stay, the latter now the connection line's wording.

## Programming

A navigation stack whose root is **Modules**.

- **Modules**: the survey list as today, with the scan's progress bar (address and count) while it runs, skeleton rows before the first module answers, and the module detail pushed from a row. A **Scan** / **Rescan** button in the toolbar.
- **Backups**: a row at the top of Modules, "Backups · last Oct 28" (or "no backup yet"), pushes today's Backup screen: Back up, Full rescan, the folder, the progress with module and identifier counts, the saved backups, Cancel. The scan-first behaviour when no module is known stays.

## Settings

Today's settings sheet as a tab: provider, sign-in or key, model, effort, prices, privacy, Clear conversations, and on the Mac the app folder. The Log button in the toolbar like every tab. The welcome and the sign-in sheets work as they do now. The AI step's own gear button goes away; Settings from the Fault codes or Mechanic screens is the tab.

## Loading

- **The pulse mark.** A view that draws the app's mark, the ink V with the orange pulse, and animates the pulse being drawn, about 1.6 s per beat, repeating. It replaces the system spinner everywhere the app waits without a count: connecting, the mechanic thinking, a read starting. On the Mechanic screen it beats beside the activity line ("Searched the web: …", "Read faults of DME"), replacing the spinner and the word "Thinking…".
- **Bars with words.** Wherever the count is known the wait is a progress bar with "what · n of m" above it: the scan (address of FF, modules answered), the fault read (module n of m · name), the backup (module n of m, identifiers n of m). The same bar style everywhere, orange on the line color.
- **Skeletons.** A list that is being filled for the first time shows three placeholder rows that shimmer until the first real row arrives: the modules during the first scan, the fault codes during a read.
- **Dynamic Type and reduced motion** are respected: the beat and the shimmer stop when the system asks for reduced motion, leaving the mark still.

## What goes, what stays

Goes: the step strip, Next, Back, Done, `Flow.step` and the per-step gating, the AI step's `onDisappear` stop, the Settings gear on the AI step, the sheet presentation of Settings. Stays: every Core type and behaviour, the theme, the conversation per car and provider, the Keychain, the log, the reconnect machinery and its states, all user-facing strings not named above.

## Constraints

- Nothing new reaches the car: the fault read sends what the health check sends today, the chip is computed from bytes already read, and no screen offers a clear or a reset.
- Core changes are limited to: a `FaultReport` value (the read's result: per-module faults with status bytes, the OBD codes, the time) that both the Fault codes screen and the mechanic's context build from, the status-chip rule as a pure function, and the "fresh enough" rule as a pure function; each with tests.
- The views have no unit tests; their check is both builds, light and dark simulator screenshots of each tab (as in the theme work), and Scott in the car.
- Swift 6 strict concurrency, `defaultIsolation(MainActor.self)`, SDK 27's `@State` rule, deployment iOS/macOS 26; no new dependencies.

## Left to the builder

The exact SwiftUI composition (one `TabView` with a sidebar-adaptable style, a `NavigationStack` per section, how the connection line is shared), the shape of `FaultReport` and how the mechanic's `HealthCheck` is built from it, the mark's path data as a `Shape`, the skeleton's implementation, and where the ten-minute knob lives.
