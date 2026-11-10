# Check my car: design

Date: 2026-11-10. Builds on the app as merged in PR 7 (four tabs: Car, Diagnostics, Programming, Settings).

## Intent

Scott wants Vynscope to be easy for people of all skill levels. Today the first screen is the adapter's form: its model and firmware, Connect, Disconnect, Forget adapter, Read. Someone who knows nothing about cars has to work out that they must connect, read the car, change tab and read the fault codes. One button should do all of that and answer in plain words. What a tinkerer needs stays in the app, behind a switch.

## Goals

- One tap on the first screen connects, reads the car, finds its systems, reads every fault code and says the result as a sentence.
- A later check of a car the app has seen takes under a minute, because the car's systems are remembered. In the car log of 2026-11-04 the scan of every address took about three minutes and the fault read about twelve seconds.
- With Advanced off, nothing on screen needs car knowledge.
- With Advanced on, every screen and control of today is there, under the new button.

## Non-goals

- AI in the check. Explain it hands the read to the mechanic that exists.
- A history of checks, a report to share, a demo car, a guided first run. Each is its own later project.
- Saying what a fault code means without the mechanic. The app has no code table.
- Any new request to the car. The wire allow-list does not change.

## Anti-goals

- A verdict that reads better than the data: a green "No fault codes" while some systems could not be read, or when nothing answered.
- A check that leaves the owner stuck: Stop works at every step, and a step that fails says what to do next.
- Hiding something Scott needs: Advanced on restores everything.

## Constraints

- The check sends only what Connect, Read, the scan and the fault read send today.
- Backups stay complete: a backup never runs from a remembered list of systems (see Remembered systems).
- No test touches the car, Anthropic or OpenAI. The real VIN, car logs and backup files are never committed; tests use `WBY73AW04RFFAKE19`.
- `@State` properties are declared with an initial value and never assigned in an `init` (SDK 27).

## Decided: what the owner sees

Scott approved the mockup of 2026-11-10 (`.superpowers/brainstorm/30196-1794329905/content/check-my-car.html`, not committed): four screens, described here.

### The check card, on top of the Car tab

- **Before a check.** The car's nickname when one is known, the button `Check my car` as the screen's one filled action, and the hint "Plug in the adapter and switch the ignition on. Nothing on the car is changed." While no adapter is remembered, a second hint: "The first time, tap within five minutes of plugging the adapter in. Enter 123456 if asked for a PIN."
- **While it runs.** One line per step. A finished step has a green check mark, the running one the pulse mark:
  - `Connecting to the adapter`, then `Adapter connected`
  - `Reading the car`, then `Car recognised · <nickname, or the VIN's last four>`
  - `Looking for the car's systems · <n> found`, with the scan's bar; only when the car's systems are not remembered
  - the fault read's own progress words, as the fault-code screen shows them
  - `Stop`, which ends the check after the request in flight and returns the card to its state before
- **The answer.**
  - The sentence: `No fault codes`, or `<N> fault codes in <M> systems`, inflected. Green only when there are no codes and every system could be read; ink otherwise.
  - Under it, in muted footnote text: `<K> active now` when any code is active, `<S> systems checked`, `<U> could not be read` when any refused or gave no answer, and the time.
  - One row per system with codes, in the read's order: its plain name (the app's description of it, else its BMW name, else `System <address>`) and the chips it has, each once, in the order active, pending, stored, old. Standard OBD codes are one more row, `Standard codes`, and count as one more system.
  - Actions: `Explain it`, filled, when there are codes; `See the codes`; and `Check again`.
- **A problem.** One line saying what to do, and `Try again`. For example: "The car did not answer. Switch the ignition on and try again.", "Bluetooth is off. Switch it on and try again.", "No adapter found. Plug it in, wait for its light and try again." The error as the app words it today still goes to the log.

Under the card, in both modes: the VIN and the nickname field, as today. Only with Advanced on: today's adapter section, Connect, Reconnect, Disconnect, Forget adapter, Read, their footers, and Also on file.

### Explain it and See the codes

- `Explain it` opens the Diagnostics tab with the Mechanic pushed. The Mechanic already reuses a read less than ten minutes old, and already says how to switch it on when there is no key or sign-in.
- `See the codes` opens the Diagnostics tab at the fault-code list.
- The check's read is the same one the fault-code screen shows; Read again there updates the card too.

### Advanced

- A switch, `Advanced`, in its own section at the end of Settings, with the footer "Shows Programming with its modules, backups and write test, the adapter's details, raw status bytes and the log."
- Saved in the user defaults; off when never set.
- Off hides: the Programming tab, the Log button on every screen, the raw status byte on fault rows, the Car tab's adapter controls listed above, and in Settings the Model, Effort and Prices sections and the Mac's app folder.
- Off keeps: Car with the check card, Diagnostics with the fault codes and the mechanic, and Settings with the AI provider, its sign-in, Privacy, Conversations and the switch.

## Decided: remembered systems

- When a walk of every address ends for a car, the addresses that answered are saved for its VIN in `known-modules.json` in the app folder. Every later full walk of that car replaces them.
- A check of a car with remembered systems walks only those addresses. A remembered system that does not answer is left out of that check without an error. When none answers, the check ends with the problem line for a silent car.
- The Modules screen's Scan and a backup's scan always walk every address.
- The app knows whether its module list came from a full walk. A backup started on a list that did not scans in full first, exactly as it does today when no module is listed.

## Decided: the verdict lives in Core

The counts and rows of the answer are computed in the Core package from the fault read, as one value with tests: the number of codes, of systems with codes, of active codes, of systems read and not read, the rows, and whether nothing answered. The card only words it.

## Left to the builder

- The check as one action that holds the adapter across its steps, reusing what Connect, Read, the scan and the fault read do today, and its step state.
- How `Explain it` reaches the pushed Mechanic.
- The plain line for each error the app can raise today, in the style of the three examples.
- View decomposition, and where the Advanced value lives so every screen sees it.

## Calls I made

- The check uses no AI, so it is free and works before any sign-in. (Approved in the playback.)
- The button lives on the Car tab; there is no new tab. (Approved in the playback.)
- Advanced starts off; Scott switches it on once on each of his devices. (Approved in the playback.)
- Remembered systems, so that only a car's first check takes minutes. The mockup's line "A car's first check also looks for its systems" promised it.
- With Advanced off, Settings also hides Model, Effort, Prices and the app folder, and the Car tab hides Also on file. Not in the playback; strike it if you want them visible.
- A green verdict only when every system could be read. In the last car log some systems gave no answer to the fault read, so the footnote will often say "could not be read".
- Standard OBD codes count as one more system.
- The first-connection hint about the five minutes and the PIN stays visible in simple mode, because pairing needs it.

## What Scott verifies

At the desk, without the car:

- Advanced off: three tabs, no Log button, Settings without Model, Effort and Prices. Advanced on: everything as today.
- Check my car with Bluetooth off and with no adapter in range: the problem line and Try again.

In the car:

- From a cold launch, one tap ends in an answer that matches the fault-code screen. Stop works during each step.
- A second launch's check takes under a minute.
- Explain it gets the mechanic's explanation; See the codes shows the list.
- With Advanced on, a backup after a quick check still walks every address first.
