# AI Mechanic: design

Written 2026-10-26 from the design conversation with Scott Brant. Status: draft, awaiting the builder check and Scott's approval. This is a second product on the foundation the BMW coding app builds; that app's design is `2026-10-26-bmw-coding-app-design.md` in this folder and this document assumes it.

## Intent

An owner plugs an OBD-II adapter into the car, opens the app, connects, and switches on AI mode. From then on an AI mechanic can see inside the car: it reads fault codes, module data and live values, explains what it finds in plain language, looks things up on the web with sources shown, and walks the owner through fixing the problem or into the dealership informed. Where the app can change the car, the mechanic proposes the change and the owner confirms it through the app's own guarded write path.

Why: Scott wants this for himself first, and ultimately for anyone with any car, so that people can fix their own problems without being technical and without going to a dealer uninformed.

## Stages

Agreed order, each usable in the driveway before the next starts:

1. **Scott only, read-only.** His own API key. Diagnosis and explanation over the BMW module data the coding app already reads, plus fault codes and standard OBD-II where the car answers. Web lookup. No writes of any kind. This document specifies stage 1 fully.
2. **Guided edits.** After BMW phase 3 exists: the mechanic can propose a coding change or clearing a fault code; each goes through the confirm-and-write screen. Sketched below.
3. **The product.** Other people, any car: a backend that holds the API key, accounts and billing, standard OBD-II for every car with per-make depth, App Store distribution. Sketched below; it gets its own design when stage 2 is verified.

## Goals (stage 1)

- Switching AI mode on runs a health check and opens a chat whose first message is a plain-language summary of the car's state: what matters, what does not, with sources for anything looked up.
- The owner can ask anything about the car; the mechanic answers from the car's data, re-reading a module when it needs to, and from the web.
- Every claim that came from the web carries its source. Every read the mechanic makes is visible in the chat and in the app's log.
- Works identically on the iPhone and the Mac.

## Non-goals (stage 1)

- Any write to the car: no coding changes, no clearing codes, no actuator tests, no resets. The mechanic has no tool that writes, so it cannot write even if asked; it explains what it would do and says the buttons arrive in stage 2.
- A backend, accounts, billing, App Store, other people's cars, other makes' module tables. Standard OBD-II is make-neutral already; make-specific depth beyond BMW is stage 3.
- Voice, photos, camera, a knowledge base of repair manuals. The web search tool is the knowledge base.
- Running the backup or the module scan from the chat. The mechanic asks the owner to run them from the steps.

## Anti-goals

- A mechanic that writes. Stage 1 ships with no write tool; stage 2 adds exactly one proposal tool that opens the confirm screen and never touches the bus itself.
- Confident nonsense. Answers that cite nothing when they came from the web, or that state a fault's meaning as fact when the code is unknown, are failures. The mechanic says when it is guessing.
- Hidden cost. The owner sees what each conversation cost and where the data went.
- Silent refusals. If the model declines to answer, the chat says so in one line instead of showing nothing.

## Constraints

### The Claude API

- One endpoint: `POST https://api.anthropic.com/v1/messages`, headers `Content-Type: application/json`, `x-api-key`, `anthropic-version: 2026-10-21`. Swift has no official Anthropic SDK, so the app talks raw HTTP with `URLSession` and `Codable`; no third-party packages.
- Model: `claude-opus-5-5`, the current Opus, unless Scott picks another in settings. Thinking is always on for this model; the `thinking` parameter is omitted. Depth is set explicitly with `output_config.effort`: `medium` for chat turns, `high` for the health-check summary. `temperature` and friends are not sent.
- Streaming: every request sets `stream: true` and the app parses the Server-Sent Events (`message_start`, `content_block_start`, `content_block_delta` with `text_delta` and `input_json_delta`, `content_block_stop`, `message_delta` carrying `stop_reason`, `message_stop`), rendering text as it arrives. `max_tokens` 16000.
- Tools: the app's own tools are declared with `name`, `description`, `input_schema` and `strict: true`; `tool_choice` stays `auto` (this model rejects forced tool use), with the system prompt saying which tool to use when. The loop: when a response ends with `stop_reason: tool_use`, the app runs every requested tool, appends the full assistant content and one `user` message holding all `tool_result` blocks (failures with `is_error: true`), and asks again; it stops on `end_turn`. A hard cap of 12 tool rounds per owner message. Tool inputs are parsed as JSON and validated before anything runs.
- Web: the server-side tools `{"type": "web_search_20260209", "name": "web_search"}` and `{"type": "web_fetch_20260209", "name": "web_fetch"}` are declared; Anthropic runs them. `web_search_tool_result` blocks and the citations attached to text blocks give the URLs and titles the chat shows as sources. A `stop_reason` of `pause_turn` is resumed by re-sending the conversation unchanged.
- Refusals: `stop_reason: refusal` is possible. Requests carry `fallbacks: "default"` with the header `anthropic-beta: server-side-fallback-2026-07-01` so a declined turn is re-run on a fallback model server-side; if the final answer is still a refusal, the chat shows "The model declined to answer this" and the conversation continues.
- Caching: the tool list and the system prompt, with the health-check car context as the last system block, carry `cache_control: {"type": "ephemeral"}` so follow-up turns re-read the car context from cache; the app watches `usage.cache_read_input_tokens` and the log notes when it is zero.
- Errors: 429, 500 and 529 are retried with backoff (three tries); 400, 401, 402, 403, 404 and 413 are shown to the owner in one line with the API's message. The API key never appears in the log.
- No assistant prefill. All formatting is asked for in the system prompt.

### Key, privacy, cost

- The owner's own API key, entered once in a Settings screen and stored in the Keychain. The app never logs it and never sends it anywhere but `api.anthropic.com`.
- Each conversation sends the car's data (VIN, module identifications, fault codes, coding bytes the mechanic asks for) to Anthropic. Settings say so in one sentence.
- After each turn the chat shows the turn's token usage and an estimated cost from a built-in price table that Scott can edit in settings; the conversation header shows the running total.

### The car

- Everything the mechanic reads goes through the coding app's `Diag` layer and the same one-command-at-a-time adapter link. AI mode is available only while the car is connected and the VIN is read.
- Fault codes on BMW modules: UDS ReadDTCInformation, service `0x19` sub-function `0x02` (report DTCs by status mask, mask `0xFF`), per module, returning the 3-byte DTC and its status byte. This service joins the allowed request list of the coding app: it is a read, and the list becomes adapter setup, `0x22`, `0x19`, `0x3E`, `0x10 0x03`.
- Standard OBD-II, for any car: mode `03` (stored codes), mode `07` (pending codes), mode `09` PID `02` (VIN), mode `01` PIDs the car reports supported (readiness at PID `01`, control module voltage at `42`, and whatever else PID `00`/`20`/`40` advertise). These use the functional header `7DF` with the adapter's CAN auto-formatting on, and responses may come from several ECUs. The i4 is an electric car and may answer little or nothing here; the module-level reads carry the load on it. `Diag` gains a standard-OBD mode that switches the adapter between the two addressing schemes.
- Live values on BMW modules: the mechanic may read any identifier on any module with `0x22`; it is a read. The app caps it at 40 such reads per owner message so a curious model cannot sweep a module from the chat.

### Platform

- The same SwiftUI app and the same `BMWCodingCore` package as the coding app; this design adds to both. Swift 6, strict concurrency, main-actor isolation, Swift Testing, no third-party packages, xcodegen project, Scott's team and bundle prefix.
- Working style as in the coding app: smallest thing that works, one runnable check per non-trivial piece, nothing built before Scott approves this document, each stage verified in the car before the next.

## Decided: the screens (stage 1)

Chosen from mockups on 2026-10-26 (`.superpowers/brainstorm/*/content/ai-mode.html`): shape A, a fifth step with a health check.

### 5 AI

A fifth step after Backup, enabled once the car is connected and the VIN is read; the step indicator reads `1 Connect · 2 Car · 3 Modules · 4 Backup · ✦ AI`. The four manual steps are unchanged. Entering the step the first time in a session runs the health check with a progress line (`Reading fault codes from FZD__35 …`), then opens the chat with the mechanic's summary already streaming.

### The chat

A conversation view: the mechanic's messages on the left, the owner's on the right, a text field at the bottom. While the mechanic works, each tool call shows as a one-line activity entry in the conversation (`Read 3 fault codes from BDC_BODY3`, `Searched the web: "B1F3E BMW G26"`), so the owner sees every read. Web claims end with numbered sources; tapping a source opens it. After each mechanic turn, a small line shows tokens and estimated cost. Two or three suggested follow-up questions appear as tappable chips when the mechanic offers them (it is asked to end a summary with up to three). A Stop button cancels the current turn. The conversation scrolls, persists on the device per car, and a New conversation button starts over; the health check is re-run on request, not on every entry.

### Settings

Reachable from a gear on the AI step: API key (entered once, shown masked, Keychain), model (default `claude-opus-5-5`, a short list), effort for chat turns (default medium), the price table, the one-sentence privacy note, and a Clear conversations button.

### Mac

Identical. The chat is the same view in the same window; the log window shows the adapter traffic the mechanic causes, exactly as for manual steps.

## Decided: what the mechanic can do (stage 1)

### Health check

Run by the app, not by the model, before the first message: VIN and nickname; the module list with identification and coding files (already in memory from step 3; if step 3 has not run, it runs now); fault codes from every listed module (`0x19 0x02`); standard OBD-II stored and pending codes, readiness and supported mode `01` values where the car answers. The result becomes the car context block in the system prompt and the first user turn is a fixed sentence asking for the summary.

### Tools the model can call

Six client-side tools, all reads, plus the two server-side web tools. Names, inputs and what they return:

- `get_vehicle` (no input): VIN, nickname, chassis if known, adapter model and firmware, the list of modules with address, name, description, signed flag, hardware, software and coding files, and whether a backup exists and when.
- `read_faults` (`module`: diagnostic address as hex string, or `"obd"`): the module's DTCs as `[{code: hex, status: hex}]` from `0x19 0x02`, or for `"obd"` the stored and pending codes from modes `03` and `07` as standard `P/C/B/U` strings. Empty list means none; `is_error` with the reason if the module did not answer.
- `read_identification` (`module`): the identification identifiers the module answered, as hex, plus the parsed coding-file names.
- `read_coding` (`module`, optional `did` hex): with no `did`, the identifiers present in the latest backup for that module and their sizes; with a `did`, that identifier's bytes as hex from the latest backup, or a live `0x22` read if there is no backup. Says which it did.
- `read_value` (`module`, `did` hex): a live `0x22` read of one identifier, bytes as hex. Capped at 40 per owner message.
- `read_obd` (`pid` hex): one mode `01` PID, raw bytes as hex per responding ECU; the model decodes them.
- `web_search`, `web_fetch`: server-side.

The system prompt names each tool's purpose and when to call it; descriptions in the tool definitions say the same in one or two sentences each. The model is told it cannot change anything about the car, that the owner can run Backup and the module scan from the steps, and to say so when asked.

### The system prompt

Written by the builder from these points, in plain English: you are a mechanic talking to the car's owner; be concrete and brief; prefer reading the car over guessing; say which module and code you are talking about; when you looked something up, cite it; distinguish what the car reports from what you infer; never claim to have changed anything; end summaries with up to three suggested questions; the car context follows. The car context block is JSON from the health check, pretty-printed and key-sorted so it caches.

## Code shape (stage 1)

In `BMWCodingCore`: a `ClaudeClient` (request/response `Codable` types for the subset of the Messages API used here, SSE parsing, the tool loop, retries, usage accounting), `Mechanic` (the tool implementations over `Diag`, the health check, the system prompt, the per-message read cap), `DTC` (parsing `0x19` responses and standard OBD code strings), and the standard-OBD mode in `Diag`. In the app: `AIStep`, `ChatView`, `AISettingsView`, a Keychain helper, and a `Conversation` store on disk per VIN. Tests: SSE event parsing from recorded fixtures, the tool loop against a fake HTTP transport (never the real API), tool-input validation, DTC parsing, the standard-OBD addressing switch against `FakeLink`, the read cap. No test calls Anthropic.

## Stage 2: guided edits (sketch)

After BMW phase 3. One new tool, `propose_change` (`module`, `did`, `newBytes` hex, `reason`), that opens the coding app's confirm-and-write screen with the proposal filled in; the write happens only when the owner confirms there, through the backup-write-readback sequence; the tool result tells the model whether the owner confirmed and what the read-back showed. A second tool, `propose_clear_faults` (`module`), does the same for clearing codes (UDS `0x14`) once the owner has confirmed. Signed modules stay unwritable. Mockups when the stage starts.

## Stage 3: the product (sketch)

Other people, any car. A small backend that holds the Anthropic key and forwards chat requests for signed-in users with per-user limits, so the app never ships a key; accounts and billing; the standard OBD-II path as the baseline for every car, with per-make module tables and fault-code decoding added make by make; App Store distribution, a privacy policy, and advice disclaimers reviewed before launch. Its own design document, written after stage 2 is verified.

## Left to the builder

- SSE parsing details and the request/response types.
- The Keychain wrapper and the settings storage.
- DTC byte layout per BMW module family and the standard OBD code decoding; verified in the car.
- Which mode `01` PIDs the i4 answers, if any.
- Prompt wording, the price table's initial values, the chip extraction.
- How tool activity lines and sources are laid out in the chat.

## What Scott verifies (stage 1, i4)

- Switching AI mode on runs the health check and the summary names the real fault codes the car has, or says there are none.
- A question about a code gets an answer with at least one web source, and the source opens.
- Asking the mechanic to change a setting or clear a code gets an explanation and no write: the log shows only adapter setup, `0x22`, `0x19`, `0x3E`, `0x10 0x03` and the standard OBD requests.
- The cost line matches the usage the API reports; the key is nowhere in the log.
- The same conversation works on the Mac and on the iPhone.
