# Write test: design

Date: 2026-11-08. Builds on `2026-10-26-bmw-coding-app-design.md` (its phase 3) and on the app as merged in PR 6 (four tabs, Programming → Modules → module detail).

## Intent

Scott wants Vynscope to become his own coding tool, in place of BimmerCode, which he does not have. Writing options needs a map of where each option lives inside a module's coding data, and there is none yet: no coding tool to learn from, and BMW's definitions are not to hand. A G20 cheat sheet Scott supplied names modules, identifiers, bit masks and values, but not the byte inside each identifier, and 78 of its 84 rows sit on modules that are signed on the i4.

One question decides whether chasing that map is worth it on each car: which modules accept a write at all. On the 2024 i4 the head unit, body controller and instrument cluster are signed and are never written. Whether any other module takes a plain write is unknown.

The write test answers it without changing anything on the car. It writes a module's coding back exactly as the module holds it, reads it back and compares. It is also the first working piece of phase 3's write path, proven in the car before any option exists.

## Goals

- On an eligible module, write every coding identifier back unchanged, one at a time, each confirmed by a read-back that matches byte for byte.
- Report per module whether it accepted the write, and when it refused, the module's answer in words and as its code.
- Prove the pieces option writes will reuse: sending a request longer than one frame, the write request itself, the read-back comparison and the stop rules.

## Non-goals

- Options, decoding, or any change to a coding value. The write test never writes a byte the module did not just give.
- Restoring a module whose coding differs from its backup. That needs the apply step, a module reset or a coding-end routine, which is found on the car when options arrive.
- Any module outside the eligible list below. Signed modules, ever.
- Security access (`0x27`). A module that asks for it is reported as needing it.
- The AI mechanic writing. It gets no write tool, and its tool list does not change.
- The F-series car. No module of it is eligible yet.

## Anti-goals

- A change to the car. Every byte written is one the module gave in the same run, agreed by two independent reads.
- A write sent twice. Nothing sends a write again: not a reconnect, not a response pending, not a busy answer.
- A result that says "accepted" without a read-back that matches.
- A write to the crash-safety module, a powertrain, battery or charging module, or any module the app cannot name.

## Constraints

- The wire allow-list after this step: adapter setup and the adapter's own battery-voltage reading; `0x22`; `0x19 0x02` with mask `FF`; `0x3E`; `0x10 0x03`; the standard OBD modes 01, 03, 07 and 09 on `7DF`; and WriteDataByIdentifier (`0x2E`), sent by the write test only, under every rule in this document. Still never sent: `0x11`, `0x14`, `0x27`, `0x31`, any `0x10` other than `0x03`, and `0x2E` from anywhere else.
- Eligible modules: on the i4 (VIN prefix `WBY73`), the roof functions module at `0x56` (`FZD__35`) and the climate module at `0x78` (`IHKA_PRO2`). Nothing else on the i4 and nothing on any other car. Adding a module is a code change Scott decides, after the earlier ones have passed in the car.
- The Core package enforces eligibility itself and refuses any other module; a missing button is not the guard. A module that `ModuleTable.isSigned` reports as signed is refused even if it is ever added to the eligible list.
- The bytes written come from one source: a fresh read of the module taken in the same run, which must agree with the module's entry in the newest earlier backup where that module is complete. Agreement means the same coding files, the same set of identifiers and the same bytes for each. Any difference, a partial fresh read, or no such backup means nothing is written.
- No public API sends a write with bytes the caller chooses. The write request stays internal to the Core package; the only public way to send one is the write test.
- A write is sent once. A link drop, a timeout, a response pending (`0x78`) that is not resolved in time, or a busy answer (`0x21`) ends the test with what was confirmed so far. The existing re-ask after `0x78`, which sends the request again, and the existing rerun of an operation after a reconnect, must not apply to writes.
- Tests talk to the fake link only. No test touches the car, Anthropic or OpenAI. The real VIN appears nowhere in the repository; tests use `WBY73AW04RFFAKE19`. No car log or backup file is committed.

## Decided: what Scott sees

- Module detail gains a Write test section at the bottom, on eligible modules only. It says: "Writes this module's coding back unchanged to see whether it accepts a write. Nothing on the car changes." Under it is the Write test button. Other modules show no section.
- The button is unavailable while anything else runs (a scan, a backup, a fault read, a mechanic turn), while the car is not connected or not read, and when no backup holds the module complete; a line under it says which ("Back up the car first" for the last).
- Before anything is written, a confirmation names the module, the number of identifiers and their total size, the date of the backup it was checked against, the battery voltage, and "Park with the ignition on". Its buttons are Write test and Cancel.
- While it runs, the connection line shows it like other work: `Write test · identifier 3 of 12 · Roof functions`. Stop ends it between two identifiers, never inside one.
- The result stays on the module's screen for the session: Accepted, with how many identifiers were written back and read back identical; Refused, with the identifier, the answer in words and its hex code; or Stopped, with why. A read-back that differs is shown with both values and a line saying to read the module's fault codes before doing anything else. The log keeps every request and answer.

## Decided: the run

1. **Reference.** The newest backup in which the module is complete. Without one the run does not start.
2. **Fresh read.** A one-module backup of the module through the existing backup run, which reads its remembered identifiers in seconds. It is saved as a backup file like any other. A partial read stops the run.
3. **Compare.** Coding files, identifiers and bytes against the reference. Any difference stops the run and lists the differing identifiers with both values, as "changed since the backup". Nothing is written.
4. **Voltage.** Read from the adapter. Under 12.0 V, or unreadable, stops the run.
5. **Confirm.** The confirmation above. Cancel ends the run with nothing sent past the reads.
6. **Session.** The extended session (`0x10 0x03`), held with TesterPresent whenever two seconds pass, as the coding read does. A refusal stops the run as "refused the extended session".
7. **Write and read back.** For each identifier, in ascending order: write it (`0x2E`, the identifier, the fresh bytes); the answer must be positive and echo the identifier (`6E` and the identifier). Then read it (`0x22`) and compare with the bytes written. The next identifier goes only when both hold. The first refusal, missing answer or mismatch ends the run.
8. **Result** as described above.

## Decided: sending more than one frame

A write carries the identifier's whole data. With BMW's addressing a single frame carries six bytes of request, which leaves three bytes of data after the service and the identifier, so most writes need several frames. Phase 1 only ever received multi-frame answers; this step adds sending them: a first frame, the module's flow-control answer, then consecutive frames at the block size and separation time the module asks for. An overflow answer, a wait longer than the module's own limits allow, or no flow control at all ends the exchange, and the module discards the partial message, so nothing is written. The positive answer to a write fits one frame.

## Left to the builder

- How the CX is driven to send multi-frame requests and to read the battery voltage, with their timeouts, verified in the car through the log, as the phase-1 receive side was.
- The plain-words names of UDS negative answer codes.
- How long a response pending to a write is waited for before the run gives up, as long as it is bounded and nothing is sent again.
- Code shape: a Core type for the run with the link and clock injectable for tests, the Flow plumbing, the section view.

## Calls I made after Scott's approval of the outline

- The button says Write test, not Restore from backup, because this step only ever writes back bytes the module already holds. Restore arrives with the apply step.
- When the module's coding differs from its backup, the run shows the difference and writes nothing, so the step can never change the car.
- Two eligible modules instead of every module off the signed list. On an electric car the unnamed modules include the battery, drive and charging electronics, and the crash-safety module holds the airbags. The list widens one module at a time, by Scott's decision.
- The 12.0 V floor.
- Results last the session; the log keeps them after that.

## What Scott verifies in the car

- A full backup of the i4 completes, with roof functions and climate complete.
- Fault codes for both modules, read before the test.
- Write test on roof functions: a result is shown, and the log shows only adapter setup, the voltage reading, the reads, `0x10 0x03`, `0x3E` and the writes, each write sent once.
- Ignition off and on again: the interior lights, the sunroof if fitted and the rest of the roof console behave as before, and its fault codes show nothing new.
- The same for climate: heating and cooling work after an ignition cycle, and nothing new in its fault codes.
- No other module shows the Write test section.
