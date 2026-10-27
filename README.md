# Vynscope

A BMW coding app for iPhone and Mac: one SwiftUI app, CoreBluetooth on both, talking to an OBDLink CX in the car. Read-only diagnostics ship first; an AI mechanic mode is designed and planned.

## Status

Phase 1 is built and awaiting in-car verification on a 2024 i4: pair with the adapter, read the VIN, list the modules with their identification and coding files, and back up the raw coding to disk. Nothing is written to the car in this phase.

## Build

Requires Xcode 27 and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
make project   # generates Vynscope.xcodeproj
make test      # runs the Core package tests
make mac       # builds and opens the Mac app
```

## Layout

- `Core/` — the `BMWCodingCore` Swift package: adapter commands, ISO-TP, UDS reads, module discovery, VIN, coding sweeps, backups and the Bluetooth link, with its tests.
- `App/` — the SwiftUI app for both destinations.
- `BRIEF.md` and `docs/superpowers/` — the brief, the approved designs and the phase 1 plan.

VINs in the tests and docs are placeholders.
