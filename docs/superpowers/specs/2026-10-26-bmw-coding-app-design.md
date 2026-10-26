# BMW coding app: design

Written 2026-10-26 from the design conversation with Scott Brant. Status: builder check done and folded in; awaiting Scott's approval. `BRIEF.md` at the repo root is the fact sheet this grew from; this document is the one a builder plans from.

## Intent

Scott wants his own BMW coding tool instead of paying for BimmerCode. He has two cars and an OBDLink CX adapter. The app is one SwiftUI app with iPhone and Mac destinations. The Mac build is the test rig he runs in the car while the app is being built; the iPhone build is what he uses day to day.

The work ships in phases, each verified by Scott in the car before the next starts. Phase 1 only reads. Phase 2 decodes what was read. Phase 3 writes, narrowly. A later phase never widens an earlier one.

## Goals

- Phase 1, read-only: connect to the CX, show the adapter's model and firmware, read the VIN, list the modules that answer, show each module's identification and coding files, and save every module's raw coding data to a file. The first thing the app does is leave Scott with a complete backup.
- Phase 2, decode: with option tables Scott supplies, show each module's options with their current values, using BimmerCode's option names where they apply. First target: the seat belt chime on `ACSM_5`.
- Phase 3, write: change an option on an unsigned module only, always after a fresh backup of that module and always followed by a read-back that confirms the change. First target: the seat belt chime, if `ACSM_5` turns out to be unsigned.

## Non-goals

- Any car that needs K-line or Bluetooth Classic. Both of Scott's cars talk CAN over the OBD port; nothing else is supported.
- Any adapter but the OBDLink CX. Other BLE adapters with the same UART service may happen to work; they are not tested.
- Clearing fault codes, live data, dashboards, service functions, flashing, vehicle order (FA) editing.
- Writes to the head unit (`HU_MGU`), the body domain controller (`BDC_BODY3`) or the instrument cluster (`KOMBI`) on the i4. Their coding is signed per VIN by BMW's backend and the module rejects unsigned writes. The app reads them like any other module.
- Parsing BMW's binary CAFD definition files. The app reads a plain option table Scott produces from them (format in phase 2). How he produces it is outside the app.
- App Store distribution, CarPlay, Android, Windows.

## Anti-goals

These would make the app a failure even if every feature worked.

- Bricking a module. There is no write path that skips the backup or the read-back, no write to a signed module, no raw command console, and nothing in phase 1 sends anything but reads and adapter setup.
- A backup that lies. A backup file that is missing a module, or has a module with empty coding data, must say so on screen and in the file. Silence is the failure.
- A framework. No adapter abstraction layer, no plugin system, no generic diagnostic stack. The app knows one adapter, one addressing scheme, and the handful of requests the three phases need.

## Constraints

### Hardware

- Adapter: OBDLink CX. Bluetooth Low Energy only, STN chipset, ELM-style `AT` commands plus `ST` commands. BLE layout from OBDLink's adapter notes: UART service `FFF0`, notify characteristic `FFF1` (adapter to host), write characteristic `FFF2` (host to adapter), Device Information service `180A` with model and firmware strings. Maximum ATT MTU 247; writes are chunked to the negotiated maximum write length. Bonding is only open for five minutes after the adapter is powered; the legacy PIN is `123456`. Source: https://support.obdlink.com/support/solutions/articles/43000746707-obdlink-cx-adapter-notes
- Car 1: 2024 BMW i4 eDrive40, chassis G26, VIN `WBY73AW04RFFAKE19`, US spec, iDrive 8.5. Secure Coding 2.0 applies: `HU_MGU`, `BDC_BODY3` and `KOMBI` carry signed coding. Other modules seen on this chassis: `ACSM_5`, `FZD__35`, `RAM`, `IHKA_PRO2`, `HKFM_2015`, `CFAS_S15`/`CBFS_S15`, `SAS2`. Which of those accept plain writes is read from the car, never assumed.
- Car 2: an F-series X3 (F25) or X5 (F15). Exact year and model are confirmed from the VIN the first time it connects. No signed coding on this generation.
- Both cars use BMW's diagnostic addressing over 11-bit CAN at 500 kbit/s: the tester is address `0xF1`; requests go out on CAN id `0x6F1` with the target module's address as the first data byte; a module answers on CAN id `0x600` plus its address, with `0xF1` as the first data byte. ISO-TP framing follows inside. The option universe for the i4 is BimmerCode's own list, grouped by module: https://bimmercode.app/vehicles/i4/

### Platform

- One Xcode project, one app target with iPhone and Mac destinations, SwiftUI throughout, CoreBluetooth on both. Not Catalyst. Scott's Xcode and device signing already work; the project uses his existing team.
- Current OS releases on his devices; the builder sets the deployment target to the current major version.
- No third-party packages.
- Working style: lazy senior developer. The smallest thing that works, no speculative abstractions, one runnable check per non-trivial piece of logic. Tests exist to catch broken parsing and sequencing, not for coverage.

## Decided: the screens

Approved from mockups on 2026-10-26 (the HTML lives under `.superpowers/brainstorm/`, which is git-ignored). The app is a step-by-step flow, one screen per step, Next and Back between them. Scott chose this over a single screen that fills in and over tabs.

### 1 Connect

Scans for the CX, connects, bonds if needed, then shows the adapter's model and firmware read from the Device Information service and from the adapter's own identification commands. Shows a hint that bonding only works for five minutes after the adapter is plugged in and that the PIN is `123456` if asked. Next is enabled once the adapter answers a command. On later launches the app reconnects to the last adapter on its own.

### 2 Car

Tells the user to turn the ignition on. Reads the VIN from the car and shows it. The first time a VIN appears, the user gives it a nickname; after that the car is recognised and shown with its nickname, and the other car on file is shown greyed out. Next is enabled once a VIN is read.

### 3 Modules

Probes the module addresses and lists modules as they answer: name, a plain-language description, and a badge. The badge says `signed` for modules whose coding is signed and shows a chevron otherwise. An address that is not in the app's name table is listed by its address alone and is still backed up. Tapping a row opens the module detail. Next moves to backup.

### 4 Backup

Reads every coding identifier each listed module answers and writes them all to one file. Shows a progress bar and a row per module with its state: done with a count and size, reading, waiting, or failed with the reason. Done is enabled only when every module is accounted for. Where the file went is shown on screen. The first backup of a car sweeps every identifier and takes about an hour; the screen says so up front. Later backups reuse the remembered identifier sets and take minutes. A full-rescan button forces the hour-long sweep again.

### Module detail

Opened from a module row. Shows the module's name, description and diagnostic address; its identification (part number, hardware version, software version, and whether its coding is signed); its coding files (CAFD ids with versions); and its coding data as a read-only hex listing with a count and total size.

Opening the detail never starts a coding read. Identification and coding files were read during discovery, so a tap mid-scan shows them at once. The coding data section shows what has already been read: this run's backup if Backup has run, otherwise the latest backup file for this car, otherwise one line saying to run Backup. (My call, made after the builder check.) Phase 2 adds an Options section here.

### Log

Reachable from a Log button on every step. A sheet on the iPhone, a second window on the Mac. Shows every command sent and every line received, with timestamps and direction. Share sends the whole log as text. The log is also appended to a file in the app's folder as it happens, so a crash in the car still leaves a record.

### Calls Scott accepted with the mockups

- The app reconnects to the last adapter on its own.
- Backups are one JSON file per run, named by date, time and car nickname. On the iPhone they live in the app's folder, visible in the Files app. On the Mac they go to a folder picked once; the choice persists.
- Module names and descriptions come from a small built-in table keyed by diagnostic address.
- Nothing on any step sends a write. There is no raw command console in phase 1.

### Calls I made after the builder check

- The module detail is a view of what has already been read; it never starts a coding sweep.
- Phase 1 may put a module into the extended diagnostic session to read coding data that the default session refuses, and holds it with tester-present. Nothing else beyond reads goes out.
- On the iPhone the app keeps the screen awake while a backup runs and declares the Bluetooth central background mode, so a locked phone does not drop the adapter mid-backup.

### Mac

The same four steps in a window, sized like a phone screen or wider; no separate layout. The log opens as a second window. Everything the iPhone build does, the Mac build does identically, so a bug seen on the test rig is a bug in the app.

## Decided: how it talks to the car

### Adapter transport

CoreBluetooth central. Discover by service `FFF0`, subscribe to `FFF1`, write to `FFF2`. The adapter speaks a line protocol: the app writes a command ending in carriage return; the adapter replies with lines and then a `>` prompt. One command is in flight at a time, enforced by a single actor that owns the peripheral; the actor exposes one call that sends a command and returns the response lines up to the prompt, with a timeout. Everything above the transport is written against that one call, which is also the seam the tests use: a fake that returns canned lines.

Adapter setup after connect: reset, echo off, headers on, spaces off, CAN protocol 11-bit 500 kbit/s, CAN auto-formatting off (the app builds ISO-TP frames itself because BMW's target address sits in the first data byte), tester header `6F1`, and a flow-control frame of the form `XX 30 00 00` using the adapter's custom flow-control commands so multi-frame responses flow. Per module the app sets the receive filter to `6XX` for that module's address. The app reassembles multi-frame responses from raw frames. The exact command list and timings are verified in the car through the log; the reference for the approach is `tronikos/elm327_obdii` (Python), which drives the same `FFF1`/`FFF2` adapters and switches headers and filters per module. It is a reference, not a dependency.

### Requests

All vehicle reads are UDS ReadDataByIdentifier (`0x22`). A negative response (`0x7F 0x22 code`) is a normal answer, not an error, and is logged as such.

- VIN: DID `0xF190`, asked of the gateway first (`BDC_BODY3` at `0x40` on the i4, `ZGW` at `0x10` on the F-series), then of any other module that answers it. Fallback: standard OBD mode `09` PID `02` on the broadcast header.
- Module discovery: for each address `0x00` to `0xFF` except the tester, set the receive filter and send one identification request with a short timeout. A module that answers is listed. Lead for the request: the SVK (installed-software table) at DID `0xF101`, which on BMW modules lists hardware, software and coding-file entries, the last being the CAFD ids. The builder confirms the DID on the car; if a module answers nothing to it, TesterPresent (`0x3E`) is the second probe so the module is still listed.
- Identification: hardware and software versions and coding files from the SVK; part number and serial from the standard identification DIDs (`0xF18C` and neighbours) where the module answers them. Fields a module does not answer are shown as not reported, never blank.
- Signed or not: read from the module's coding properties. The builder finds the identifier on the car during the DID survey, starting from the SVK's coding-file entries, which differ on signed modules. Until that read exists, the badge comes from a built-in list: the three signed modules on the i4, none on the F-series. Phase 3 is gated on both: a module listed as signed, or read as signed, is never written.
- Sessions: if a module answers a coding read with a negative saying the service is not supported in the active session or conditions are not correct, the app enters the extended diagnostic session (`0x10 0x03`) for that module, holds it with TesterPresent (`0x3E`) every two seconds while it reads, and lets it lapse when done. Session control is not a write and the module falls back to its default session on its own. It is the only request besides reads and tester-present that phase 1 sends. (My call, made after the builder check.)
- Coding data: for each module, read every DID from `0x3000` to `0x3FFF` one at a time and keep the ones that answer positively. Out-of-range negatives are skipped silently. Requests are never batched: a positive answer to a request for several DIDs cannot be split safely without knowing each DID's length. One request costs one BLE round trip, roughly 40 ms, so a full sweep is about three minutes per module and an hour or more for a car with 20 to 30 modules.
- Remembered sets (Scott's choice after the builder check): the first backup of a module sweeps the full range. The set of identifiers that answered is remembered per module, keyed by the module's address and its coding-file ids with versions, in a small JSON file in the app's folder. Later backups read only that set, which takes seconds to a minute per module. A change in a module's coding-file version drops its remembered set, so the next backup sweeps it fully again. A full-rescan button on the Backup step forces the sweep for every module. Each module in a backup file records which method produced it, so a backup never silently claims more than it read.

### Backup file

One JSON file per run, written by `Codable`:

- `vin`, `nickname`, `date`, `appVersion`
- `adapter`: `model`, `firmware`
- `modules`: an array of `address`, `name`, `signed`, `identification` (`partNumber`, `hardware`, `software`, `serial`, each optional), `codingFiles` (array of strings), `coding` (a map from DID in hex to data in hex), `method` (`fullSweep` or `rememberedSet`), and `status` (`complete`, or `partial` with a reason)

A module that failed partway through is kept with `partial` and whatever was read. The file is written once at the end; a run that is cancelled leaves no file.

### Address table

A small built-in table from diagnostic address to module name and plain description, covering the modules named in this document and the common ones on both chassis. The builder sources it from public references (ediabaslib's module lists, BimmerCode's vehicle pages). An address outside the table is shown bare.

## Decided: code shape

Suggested, not mandated. The point is small.

- `App` and the four step views, the module detail view, the log view.
- `Adapter`: the CoreBluetooth central and the command actor.
- `Diag`: BMW addressing, ISO-TP reassembly, the requests above, module discovery, backup.
- `Model`: car, module, backup, log entry. `Codable` where it hits disk.
- `Tests`: one check each for ELM line parsing (prompt detection, multi-line, negative responses), ISO-TP reassembly over the BMW scheme, SVK parsing, backup JSON round trip, and the discovery loop against the fake transport. No test touches CoreBluetooth.

Roughly a dozen source files. Swift concurrency with actors for the transport; no Combine, no third-party packages.

## Phase 2: decode

Sketch only; mockups come when the phase starts, and this section is Scott's to veto.

- Input: one JSON option table per coding file, supplied by Scott and imported into the app's folder (Files on the iPhone, the picked folder on the Mac). Format: `cafd` (the id the module reports, without version), `module`, and `options`, each with `name` (BimmerCode's name where one exists), `did`, `byteOffset`, `bitMask`, and `values` mapping a value name to its bits. Producing these tables from BMW's definition files is Scott's job outside the app.
- Module detail gains an Options section: each option's name, its current value decoded from the module's coding data, and the raw bits. A module whose coding file has no table says so. Values are read live from the car when connected, which only means the handful of DIDs the table names, never a sweep; otherwise they come from the latest backup.
- First target: `ACSM_5`, the seat belt chime.

## Phase 3: write

Sketch only; mockups come when the phase starts, and this section is Scott's to veto.

- Only modules that are unsigned by both the list and the read. The write path is one fixed sequence: fresh backup of that module, extended diagnostic session, WriteDataByIdentifier (`0x2E`) of the full DID with the changed bits, read-back of the same DID and byte-for-byte comparison, whatever the module needs to apply coding (an ECU reset or a coding-end routine, found on the car), then a second read-back. Any mismatch stops the sequence, shows both values, and keeps the backup. Restore writes the backed-up bytes through the same sequence.
- Before and after are shown on one screen and the user confirms before the write goes out.
- The builder finds on the car whether a module needs security access (`0x27`) before writing; if it does, that module is reported as not writable rather than guessed at.

## Left to the builder

- The exact adapter command sequence and timeouts, verified in the car through the log.
- The DID survey: identification fields, VIN source per car, the coding-properties identifier for signed modules.
- The address table's source.
- Probe and backup timing, batch size, flow-control details.
- Project layout, concurrency details, test framework.
- App name and icon. Default: "BMW Coding".

## What Scott verifies per phase

Phase 1 in the car, both cars:

- Adapter model and firmware match what OBDLink's app reports.
- The VIN matches the door sticker.
- The module list includes every module named in this document that the car has, and the three signed ones carry the badge on the i4.
- A backup file exists with every listed module marked `complete` and non-empty coding data for each.
- The log shows only adapter setup, `0x22` reads, `0x3E` tester-present and, where a module needed it, `0x10 0x03` session control. Nothing else was sent.

Phase 2: the seat belt chime option on `ACSM_5` decodes to the value the car actually has, and at least one other option on another module matches BimmerCode's reading.

Phase 3: the seat belt chime changes, the read-back matches, the car behaves accordingly, and restore puts it back.
