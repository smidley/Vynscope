# Bluetooth link stability — design

Date: 2026-10-28. Owner: Scott. Builds on the Core link (`BLELink`, `Diag`) and the app's `Flow` as they are on branch `followups`.

## Intent

The app talks to the car through an OBDLink CX over Bluetooth LE. Real cars drop that link: the owner walks away with the phone, the ignition cycles and the adapter loses power for a moment, the adapter sleeps after a quiet stretch, something in the cabin interferes. Today a drop fails whatever was running, forgets the car, and waits for the owner to press Connect and start over. Scott wants the opposite: the link comes back on its own and the work carries on; the owner is warned while the connection is bad; and only when the link cannot be re-established within a minute does the app stop and ask them to reconnect. None of this has been tested in a car yet; the design is preventive, so everything in it must be testable on the desk with a fake link.

## Goals

- A dropped connection re-establishes itself without the owner's help, and the command that was in flight is sent again once the adapter is back, so a backup, a scan or a chat turn's lookup continues instead of restarting.
- The owner sees a warning while the connection is bad: a weak signal, or an adapter that dropped and came back.
- If the link is not back within 60 seconds of the drop, the app stops trying, fails the work in flight with a plain message, and asks the owner to reconnect.
- A silent drop, or an adapter that has gone to sleep, is noticed within seconds while idle, not at the owner's next action.
- Every drop, reconnect and give-up is in the log with its time and reason.
- All of it is covered by package tests against a fake link; nothing needs the adapter.

## Non-goals

- Changing the adapter's own settings (its sleep timers, its programmable parameters). The app sends it nothing that persists.
- More than one adapter, Classic Bluetooth, Wi-Fi adapters.
- Resuming a backup across app launches. Within one run, a backup continues through a reconnect; after the app is quit it starts over as today.
- Any new wire traffic to the car. The allowed list is unchanged: adapter setup, `0x22`, `0x19 0x02` (mask FF), `0x3E`, `0x10 0x03`, and the standard OBD modes 01/03/07/09 on `7DF`; nothing else, and nothing that writes.

## Anti-goals

- Continuing against a different car. After a reconnect the car is re-identified before anything else; a different VIN stops the work.
- Repeating a command whose effect is uncertain. Every command the app sends is a read, so resending is safe; the design must keep it that way, and a keep-alive must never reach the car.
- Hiding trouble. A reconnect that worked is still reported, in the log and as a warning the owner can see.
- Trying forever. One minute, then the owner decides.

## Behaviour

### Link states

The link keeps its states `off`, `scanning`, `connecting`, `ready` and `failed(message)`, and gains `reconnecting(since: Date)`. `reconnecting` is entered from `ready` when the system reports the adapter gone, when Bluetooth was not switched off by the owner, and when the keep-alive gets no answer twice. It is never entered from a disconnect the owner asked for, nor during a connect that has not yet reached `ready`.

The app shows `reconnecting` wherever it shows the adapter: the Connect step's adapter row reads "Reconnecting…", the step strip's Connect entry shows it in the warning color, and a step that is waiting on the adapter (Modules scanning, Backup, a chat turn's tool call) shows "Reconnecting to the adapter…" in place of its progress text. No alert, no modal.

### Reconnecting

While `reconnecting`, the link asks the system to connect to the same adapter it had. CoreBluetooth keeps such a request pending until the adapter is in range again, so one request is the retry loop; the link does not scan. When the adapter connects, the link rediscovers its services and characteristics and subscribes again, then returns to `ready`. If it is not `ready` within 60 seconds of entering `reconnecting`, the link cancels the pending request, moves to `failed("The adapter did not come back. Reconnect when it is in range.")`, and fails whatever was waiting with `LinkError.disconnected`. The 60 seconds are wall clock, so that the window holds when the phone is locked.

### Commands during a reconnect

`send` on a link that is `reconnecting` waits for it to be `ready` again, bounded by the same 60-second window, instead of throwing; a caller sees a slow command, not an error. A command that was in flight when the drop happened is treated the same way: its write or its reply is abandoned, and once the link is `ready` it is sent again from the start. Only a command whose reply had not arrived is resent; one that had completed is never repeated.

A re-powered adapter has forgotten its setup (echo off, headers, protocol) and the module it was addressing. The link counts its reconnects; `Diag` reads that count before every command and, when it has changed, runs its setup sequence and its module selection again before the command goes out. The resent command therefore goes to the right module with the right settings. These re-run steps are the adapter setup and the select that `Diag` already sends; nothing new goes on the wire.

After the setup is redone, and before the resent command, `Diag` reads the VIN once. If it differs from the VIN the flow holds, the command fails with a message naming the problem ("A different car answered after the reconnect"), the flow forgets the car and returns to the Connect step. If it matches, the work continues and the owner sees only the "Reconnecting…" state come and go.

### Asking the owner

When the minute runs out, the step the owner is on shows the failure message and a "Reconnect" button, in the same place that step shows its errors. Reconnect runs the flow's connect as the Connect step does, re-identifies the car, and, if it is the same car, leaves the owner on their step with the car still known; the action they were running (a scan, a backup) is theirs to start again. A different car, or no car, goes back to the Connect step as today.

### Keep-alive

While `ready` and no command has been sent for 30 seconds, the link sends the adapter a bare carriage return, which the adapter answers with its prompt alone and which never leaves the adapter for the car. No answer within 2 seconds counts as a miss; two misses in a row count as a drop and start a reconnect. The keep-alive is skipped while a command is in flight and stops with the link. It keeps the adapter from sleeping and turns a silent drop into a reconnect within seconds.

### Bad-connection warning

While `ready` the link reads the signal strength every 5 seconds. Two readings in a row below −85 dBm set a warning; it clears after two readings above −80 dBm. The warning shows as a line "Weak Bluetooth signal" on the adapter row and the step strip's Connect entry in the warning color, wherever the owner is. A reconnect that succeeded shows "The adapter dropped and reconnected" the same way until the next command completes without trouble. The thresholds are the builder's starting values and are marked as calibration knobs in the code.

### The log

Each drop (with the system's reason, or "no answer to the keep-alive"), each reconnect (with how long it took), each give-up and each signal warning is one log line with its time. The signal strength is noted with each drop. Nothing else about the link is logged; command traffic stays `Diag`'s business as today.

### iPhone in the background

The app declares the Bluetooth central background mode, so the system keeps delivering the link's events while the phone is locked or the app is behind another. A pending reconnect request survives the background. The design relies on that and asks for no more; whether a backup finishes with the phone locked in the car is on the owner's in-car list, not something the desk can prove.

## Constraints

- No new wire traffic to the car and nothing that writes; the keep-alive is adapter-only.
- No new dependencies. Swift 6 strict concurrency, both platforms, the project's existing conventions.
- The reconnect, resend, keep-alive, give-up and warning decisions live in a part of the link that tests can drive without CoreBluetooth: a fake link that can drop mid-command, come back after a chosen delay, answer or ignore keep-alives and report chosen signal strengths. CoreBluetooth stays a thin layer around it.
- Every drop and reconnect is logged; nothing about the car's data is.
- The existing package tests keep passing; the allowed-list tests stay as they are.

## Tests the design asks for

- A command in flight when the link drops is sent again after the reconnect, once, after the setup and the select were redone; a command that had completed is not.
- A VIN that differs after a reconnect fails the command with its message and the flow returns to Connect.
- No reconnect within 60 seconds fails the waiting command with `disconnected` and the link ends in `failed` with the give-up message; a reconnect at 59 seconds succeeds.
- Two unanswered keep-alives start a reconnect; one unanswered followed by an answer does not; a command in flight suppresses the keep-alive.
- The signal warning sets after two readings below the low threshold and clears after two above the high one, not between.
- An owner's Disconnect during `reconnecting` ends the attempts and leaves the link `off` with nothing waiting.
- The log carries one line per drop, reconnect, give-up and warning.

## Left to the builder

The exact shape of the testable core (one state machine type or a policy type the link consults), the clock injection used by the tests, the exact keep-alive wait and the RSSI thresholds within the values above, and where in the views the warning line sits so it reads well on both platforms.
