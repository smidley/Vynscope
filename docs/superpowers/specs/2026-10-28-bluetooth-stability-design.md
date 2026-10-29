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

The link keeps its states `off`, `scanning`, `connecting`, `ready` and `failed(message)`, and gains `reconnecting(since: Date)`. `reconnecting` is entered from `ready` when the system reports the adapter gone, when Bluetooth goes off, when the keep-alive gets no answer twice, and when the probe after a command timeout gets no answer. It is never entered from a disconnect the owner asked for, nor during a connect that has not yet reached `ready`.

The app shows `reconnecting` wherever it shows the adapter: the Connect step's adapter row reads "Reconnecting…", the step strip's Connect entry shows it in the warning color, and a step that is waiting on the adapter (Modules scanning, Backup, a chat turn's tool call) shows "Reconnecting to the adapter…" in place of its progress text. No alert, no modal.

### Reconnecting

While `reconnecting`, the link asks the system to connect to the same adapter it had. CoreBluetooth keeps such a request pending until the adapter is in range again, so one request is the retry loop; the link does not scan. When the adapter connects, the link rediscovers its services and characteristics and subscribes again, then returns to `ready`. If it is not `ready` within 60 seconds of entering `reconnecting`, the link cancels the pending request, moves to `failed("The adapter did not come back. Reconnect when it is in range.")` (or, with Bluetooth off at that moment, `failed("Bluetooth is off. Switch it on and reconnect.")`), and fails whatever was waiting with `LinkError.disconnected`. The 60 seconds are wall clock, so that the window holds when the phone is locked.

### Commands during a reconnect

The link never resends a command by itself, because a re-powered adapter has forgotten its setup (echo off, headers, protocol) and the module it was addressing, and a raw resend would reach it in that state. Instead: `send` on a link that is `reconnecting`, and a `send` whose command was in flight when the drop happened, wait for the link to be `ready` again, bounded by the same 60-second window, and then throw a new `LinkError.reconnected`. Only a command whose reply had not arrived ends this way; one that had completed is never repeated.

`Diag` catches `reconnected` on every operation it runs (a DID read, a fault read, a tester-present, the standard-OBD requests, the setup itself): it runs its adapter setup again, re-identifies the car (below), restores the addressing it had (the module select, or the standard-OBD mode), and then runs the whole operation again from its start, not just the line that was cut. Its callers see a slow call, not an error. These restored steps are the setup and the select `Diag` already sends; nothing new goes on the wire. A reconnect that happened while nothing was being sent is restored the same way, before the next command goes out, because the link refuses that first command once with `reconnected`. An operation is restored and rerun at most three times; a fourth `reconnected` fails it with `DiagError.keptDropping` ("The adapter kept dropping. Reconnect when it is in range."), so a link that keeps dropping cannot loop forever.

Re-identifying the car: after the setup is redone, `Diag` reads the VIN. After an ignition cycle the modules may stay silent for some seconds, so a VIN read that gets no answer is tried again: 30 tries, each read waiting its 1.5 seconds before a 2-second pause, about 105 seconds in all with a silent car, after which the operation fails with `DiagError.carSilent` ("The car did not answer after the adapter reconnected. Is the ignition on?"). A bus error line during that wait is retried like silence. The work never continues on an unverified car. A VIN that differs from the one the flow holds fails the operation with a message naming the problem ("A different car answered after the reconnect"), and the flow forgets the car and returns to the Connect step. A VIN that matches lets the operation go on, and the owner sees only the "Reconnecting…" state come and go.

### A timeout while connected

CoreBluetooth reports a lost link only after its supervision timeout, which can be several seconds, while a car read waits 1.5 seconds for its prompt. So a drop usually shows up first as a command timeout on a link that still says `ready`. The link therefore treats a timeout while `ready` as a suspected drop: it sends the adapter one adapter-only identify command (`ATI`, 2 seconds). An answer means the adapter is there and the car was silent, and the command fails with `timeout` as today. No answer means the adapter is gone: the link enters `reconnecting`, and the timed-out command is handled as a command in flight, which `Diag` restores and reruns.

### Asking the owner

When the minute runs out, the step the owner is on shows the failure message and a "Reconnect" button, in the same place that step shows its errors. The button also appears after `keptDropping` and `carSilent`, when the link is connected but the diagnostics layer was dropped. Reconnect runs the flow's connect as the Connect step does, re-identifies the car, and, if it is the same car, leaves the owner on their step with the car still known; the action they were running (a scan, a backup) is theirs to start again. A different car, or no car, goes back to the Connect step as today. The flow's connect re-identifies the car the same way when it keeps it, the link having stayed up.

### Keep-alive

While `ready` and no command has been sent for 30 seconds, the link sends the adapter `ATI`, the identify command, which the adapter answers by itself and which never reaches the car. A bare carriage return is never used for this: on ELM-style adapters an empty line repeats the previous command, which could send a car read again. No answer within 2 seconds counts as a miss; two misses in a row count as a drop and start a reconnect. The keep-alive is skipped while a command is in flight and stops with the link. It keeps the adapter from sleeping and turns a silent drop into a reconnect within seconds.

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

- A command in flight when the link drops ends in `reconnected` once the link is back; `Diag` then redoes the setup and the select and reruns the whole operation; a command that had completed is never repeated.
- A VIN that differs after a reconnect fails the operation with its message and the flow returns to Connect; a VIN read that gets no answer, or a bus error, is retried every 2 seconds and the operation fails with `carSilent` after 30 tries.
- A fourth `reconnected` on one operation fails it with `keptDropping`.
- A timeout while `ready` sends `ATI` once: an answer gives `timeout` as today, no answer starts a reconnect and the operation is rerun after it.
- The keep-alive is `ATI`, never a bare carriage return.
- No reconnect within 60 seconds fails the waiting command with `disconnected` and the link ends in `failed` with the give-up message; a reconnect at 59 seconds succeeds.
- Two unanswered keep-alives start a reconnect; one unanswered followed by an answer does not; a command in flight suppresses the keep-alive.
- The signal warning sets after two readings below the low threshold and clears after two above the high one, not between.
- An owner's Disconnect during `reconnecting` ends the attempts and leaves the link `off` with nothing waiting.
- The log carries one line per drop, reconnect, give-up and warning.

## Left to the builder

The exact shape of the testable core (one state machine type or a policy type the link consults), the clock injection used by the tests, the exact keep-alive wait and the RSSI thresholds within the values above, and where in the views the warning line sits so it reads well on both platforms.
