# BMW coding app: project brief

Written 2026-10-26 by Claude from the originating conversation in Scott's work repo session. This file is the only context a fresh session has, so read all of it first.

## Who and why

Scott Brant (Degreed infrastructure lead; also a Swift developer with a personal macOS app at `~/Documents/dustpan` and an iOS app, GridMind, with Xcode and device signing already set up) wants his own BMW coding tool instead of paying for BimmerCode. Working style he expects: lazy-senior-dev (smallest working thing, no speculative abstractions, one runnable check per non-trivial piece of logic); ask one question at a time, with clickable options.

## Hard requirements (decided with Scott)

- It has a UI.
- One SwiftUI app with iPhone and Mac destinations, Bluetooth through CoreBluetooth on both. The Mac build is his test rig in the car; the iPhone build is daily use.
- Read-only diagnostics ship first.
- Nothing gets built until he approves the design.

## Where the brainstorm stands

Decided: platform (above). Undecided: the screens, the second BMW (year and model unknown), and the first option he wants to change on the i4. Resume with the `superpowers:brainstorming` skill: offer the visual companion for screen mockups (keep `.superpowers/` out of git), settle the screens, write `docs/superpowers/specs/<date>-bmw-coding-app-design.md`, run its builder check, then `superpowers:writing-plans`.

## Hardware and facts gathered so far

- Adapter: OBDLink CX (Amazon B08NFLL3NT). Bluetooth Low Energy 5.1 only, no classic Bluetooth, STN chipset, ELM-style AT and ST command set. OBDLink's public adapter notes give the BLE layout: UART service `FFF0`, notify characteristic `FFF1` (adapter to host), write characteristic `FFF2` (host to adapter), Device Information service `180A` with model and firmware strings; max MTU 247 and writes must be chunked to MTU minus overhead; bonding is only open for five minutes after power-on; legacy PIN `123456`. Source: https://support.obdlink.com/support/solutions/articles/43000746707-obdlink-cx-adapter-notes
- Car 1: 2024 BMW i4 eDrive40, chassis G26, VIN `WBY73AW04RFFAKE19`, Munich-built, US spec, iDrive 8.5 from the factory.
- Car 2: another BMW he has not named yet. Ask, because an older E-series may need K-line, which changes what the adapter can do.
- Secure Coding 2.0 applies to this i4: the head unit (`HU_MGU`), body domain controller (`BDC_BODY3`) and instrument cluster carry per-VIN coding data signed by BMW's backend, and the module rejects unsigned writes. Reads are open. Writes to those three modules are out of scope for this app. Other modules on the car (`ACSM_5`, `FZD__35`, `RAM`, `IHKA_PRO2`, `HKFM_2015`, `CFAS_S15`/`CBFS_S15`, `SAS2`) may accept plain writes; which ones do is learned by reading each module's coding properties, never assumed.
- The realistic option universe for this chassis is BimmerCode's own list, grouped by module: https://bimmercode.app/vehicles/i4/
- Data model of a codable option, confirmed from `~/Downloads/BMW G20 Coding Cheat Sheet - Apr 2021.pdf` (no poppler on this Mac; read PDFs with a small Swift script using PDFKit): a coding-file (CAFD) id per module, the module name, a diagnostic data identifier in the `0x3000` range, a named parameter, a bit mask, and a value given as an enum name or hex. Byte offsets inside the block and the enum encodings live only in BMW's CAFD definition files, which Scott must source himself; the app decodes with whatever files he supplies.
- Prior art checked: Deep OBD / ediabaslib is Bluetooth-classic only and cannot use the CX. `tronikos/elm327_obdii` (Python, bleak) drives `FFF1`/`FFF2` adapters and switches CAN headers and filters per module; it is the reference for the transport approach, not a dependency, since this app is Swift. OBDb's `BMW-4-Series` signalsets cover live data on the G26 platform, not coding.

## Scope by phase

Each phase is done only when Scott has verified it against the car.

0. Design doc and screen mockups approved.
1. Read-only: pair with the CX, show adapter model and firmware, read the VIN from the car, list the modules that answer, show each one's identification (part number, hardware and software versions) and its coding-file list, and save a backup of every module's raw coding data to disk. No writes of any kind, not even clearing faults.
2. Decode: with CAFD files Scott provides, show each module's options with their current values, matching the BimmerCode list where it applies.
3. Writes: only on modules whose coding data is not signed, always after a fresh backup and followed by a read-back that confirms the change; never the head unit, body controller or cluster.

## History you must know

In the originating session, two replies were withheld by the app's safety classifier: one that would have written a read-only inventory script, one that would have opened screen mockups. Do not try to reconstruct them. If a session here is stopped the same way, tell Scott plainly and stop rather than retry.

## Done for the first turn

The brainstorm is resumed with Scott and the next design question is in front of him. Keep project notes in this folder's own memory.
