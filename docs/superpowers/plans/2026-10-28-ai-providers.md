# AI Providers and Sign-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks that write SwiftUI views also load `swiftui-specialist` and `swiftui-whats-new-27` (the SDK on this Mac is 27.1).

**Goal:** The AI step runs on either of two providers picked in Settings: Anthropic on the owner's console API key as today, or OpenAI through "Continue with ChatGPT", a web sign-in that lets the mechanic spend the owner's ChatGPT plan with no key anywhere.

**Architecture:** The `BMWCodingCore` package gains a `Provider`, an `OpenAIClient` for the Responses API over the same `Transport` and SSE parser as `ClaudeClient`, a `ModelClient` protocol both clients meet so `AIFlow` runs a turn the same way on either, a `Transcript` projection that turns either provider's stored messages into the rows the chat draws, and `ChatGPTSignIn`, the OAuth sign-in (registration, PKCE, loopback redirect, exchange, ID-token check, refresh, revocation) with the network behind a small `HTTPTransport`. Conversations are stored per car and per provider in that provider's wire shape; nothing converts between them. The app gains the provider picker and sign-in row in Settings, the browser hand-off on each platform, the ChatGPT caption, welcome and limit states in the chat, and a Keychain record for the sign-in. Everything is tested against scripted transports; no test calls OpenAI or Anthropic.

**Tech Stack:** Swift 6 language mode, Swift 6.4 toolchain, SwiftUI, URLSession, Network framework (loopback listener), Security framework (Keychain, RSA signature check), CryptoKit (SHA-256, random bytes), SafariServices on iOS, Swift Testing, xcodegen 2.45, no third-party packages.

**Spec:** `docs/superpowers/specs/2026-10-28-ai-provider-login-design.md`, which extends `docs/superpowers/specs/2026-10-26-ai-mechanic-design.md`. It builds on the stage-1 code of branch `ai-mechanic-stage-1` (head d7563ac, pull request smidley/Vynscope#1), not on `main`: the work branch `ai-providers` is cut from `ai-mechanic-stage-1`, and once PR 1 has merged, `main` is merged into it. OpenAI shapes below were pinned on 2026-10-28 from OpenAI's Sign in with ChatGPT pages (`developers.openai.com/siwc/token-sharing-open-source` and its sub-pages), its OpenID discovery document, and the Responses API types of the official `openai-node` SDK; each task that sends them to the API re-reads the page it names before writing its fixtures, and a difference goes into the task's report and the fixtures follow the page.

## Global Constraints

- Deployment targets iOS 26.0 and macOS 26.0; SDK 27.1, so the `@State` macro rules apply: never give a `@State` property an initial value and also assign it in an `init`.
- Swift 6 language mode, complete strict concurrency, default actor isolation `MainActor` in the package and the app, as before. No third-party packages.
- Anthropic is unchanged: the console API key in the Keychain, `POST https://api.anthropic.com/v1/messages` with the stage-1 headers and parameters. No Claude sign-in of any kind: Anthropic's policy forbids third-party apps offering Claude.ai login or routing requests through plan credentials.
- OpenAI sign-in is the open-source "Sign in with ChatGPT" flow, exactly as its page says: authorization endpoint `https://auth.openai.com/api/accounts/authorize`, token endpoint `https://auth.openai.com/api/accounts/oauth/token`, revocation endpoint `https://auth.openai.com/api/accounts/oauth/revoke`, issuer `https://auth.openai.com`, JWKS `https://auth.openai.com/.well-known/jwks.json`, ID tokens signed `RS256`. Authorization code with PKCE `S256`, fresh `state` and `nonce` per attempt. First sign-in: `client_id=dynamic_agent_client`, `agent_name_hint=Vynscope`, `ext_agent_host_id=urn:uuid:<one per device, kept>`, `response_type=code`, `scope=openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, `resource=https://api.openai.com/v1`, `redirect_uri=http://127.0.0.1:<port>/auth/callback` (`127.0.0.1`, never `localhost`; only the port ever changes). Later sign-ins use the issued `client_id` (`oaiapp_…`), omit `agent_name_hint`, send `id_token_hint` when an ID token is kept. Exchange: form-encoded `grant_type=authorization_code` with `client_id`, `code`, `code_verifier`, `redirect_uri`, `resource`, no secret. Refresh: `grant_type=refresh_token` with `client_id`, `refresh_token`, `resource`, no `scope`. Revoke: `token=<refresh token>`, `token_type_hint=refresh_token`, `client_id`. Access tokens last 3600 s, refresh tokens 30 days and rotate. Plan usage needs `chatgpt.tokens.use.direct` among the granted scopes.
- OpenAI inference goes only to `POST https://api.openai.com/v1/responses` with `Authorization: Bearer <access token>`, `content-type: application/json`, `accept: text/event-stream`; models from `GET https://api.openai.com/v1/models`. Every request sets `store: false` and `stream: true`, sends `input` as an array and the prompt as `instructions`, puts the mechanic's function tools inside one `namespace` tool and web search as the built-in `{"type": "web_search"}`, sets `reasoning.effort`, `include: ["reasoning.encrypted_content"]`, and omits `background`, `conversation`, `max_output_tokens`, `max_tool_calls`, `metadata`, `moderation`, `multi_agent`, `prompt`, `prompt_cache_retention`, `safety_identifier`, `temperature`, `top_logprobs`, `top_p`, `truncation`, `user` and `previous_response_id`. A request is done only at `response.completed`.
- The sign-in record (tokens, issued client id, host id, identity) and the API key live in the Keychain and appear in no log entry, no file and no error text; an authorization URL is never logged. No test calls OpenAI or Anthropic: every test runs against `FakeTransport`, `FakeHTTPTransport` and `FakeLink`. One test may listen on `127.0.0.1` and connect to itself.
- The wire allow-list to the car does not change. The mechanic has no tool that writes.
- Copy, exactly: the sign-in button `Continue with ChatGPT`; the row `Signed in as <email>`; `Signed in as <email>, but Vynscope may not use your ChatGPT plan`; the caption `Using ChatGPT plan` with the link `Manage usage` to `https://chatgpt.com/settings/usage`; the welcome title `You're using your ChatGPT plan`, body `Eligible AI requests in Vynscope use your ChatGPT plan. You can manage usage in ChatGPT settings.`, button `Got it`; the limit message `Usage limit reached. Review your plan or this app's limit in ChatGPT settings.` with `Manage usage` first and `Try again` second; the usage line `on your ChatGPT plan`; the no-web line `Web search isn't available on <model> with your plan; answering from the car's data only`; the step notice `Sign in to ChatGPT in Settings to switch on the AI mechanic.`; the privacy sentence `Each conversation sends your car's data (VIN, module identifications, fault codes and any coding bytes the mechanic reads) to <Anthropic under your own API key | OpenAI on your ChatGPT plan>.`
- The repo gains an MIT `LICENSE` (Task 1); OpenAI's self-serve registration is for open-source and locally hosted apps.
- Each task ends with `swift test` green (package tasks) or a successful Mac build plus iOS simulator build (app tasks), then a commit. Commit messages end with the `Co-Authored-By` trailer the harness names for the committing model.

## Review Focus

- The ChatGPT access token expired when a turn starts: the client refreshes before the request; a refresh that fails terminally clears the tokens, the turn is recorded as failed with the usage it had, and the chat says `Sign in to ChatGPT again in Settings`. Test in Task 5 (the refresh); Task 8 checks the chat.
- The weekly cap hit after text has streamed: the turn keeps its text, records its usage, shows the limit message, and sends no further plan request until Try again. Tests in Tasks 2 and 3; Task 8 checks the message.
- Stop during an OpenAI tool round: the conversation on disk never holds a `function_call` without its `function_call_output`. Test in Task 3.
- A stage-1 conversation file (no provider field) and a stage-1 settings record still load, as Anthropic's. Test in Task 1 (the conversation); the settings record by Task 1's build and Task 8.
- A sign-in callback with a wrong `state`, an `access_denied`, or a different client id than the attempt's: rejected, nothing exchanged, nothing stored. Test in Task 5.

---

## File structure

```
LICENSE                                 MIT
Core/Sources/BMWCodingCore/
  Provider.swift                        Provider enum
  Conversation.swift     (modify)       provider on Conversation and TurnRecord, files per provider, Transcript items for both shapes
  ClaudeAPI.swift        (modify)       Usage gains reasoningTokens
  ClaudeClient.swift     (modify)       URLSessionTransport(url:); ModelClient conformance; Turn.webSearchDropped
  ModelClient.swift                     ModelClient protocol, HTTPTransport protocol + URLSessionHTTPTransport
  OpenAIAPI.swift                       ResponsesMessage, OpenAIError, ResponsesAssembler
  OpenAIClient.swift                    OpenAIRequest body, OpenAIClient (send with retries, tool loop, no-web resend)
  Mechanic.swift         (modify)       systemPrompt(carContext:web:), ownerMessage(_:provider:)
  ChatGPTSignIn.swift                   PKCE, authorization URL, callback, token requests/responses, ID token, revocation, account record, SignIn orchestration
  LoopbackListener.swift                the 127.0.0.1 redirect listener
Core/Tests/BMWCodingCoreTests/
  FakeTransport.swift    (modify)       Responses stream fixtures; FakeHTTPTransport
  ProviderTests.swift ConversationTests.swift (extend) OpenAIAPITests.swift OpenAIClientTests.swift
  MechanicTests.swift (extend) ChatGPTSignInTests.swift LoopbackListenerTests.swift
App/
  AIFlow.swift           (modify)       provider, credentials, client per provider, OpenAI turn states
  AISettingsView.swift   (modify)       provider picker, sign-in row, model list, welcome
  ChatGPTBrowser.swift                  opening the sign-in page: NSWorkspace / SFSafariViewController sheet
  Keychain.swift         (modify)       the ChatGPT account record beside the key
  AIStep.swift           (modify)       the provider's notice
  ChatView.swift         (modify)       rows from Transcript items, caption, limit message, no-web line, usage line
```

---

### Task 1: Provider, conversations per provider, settings, license

**Files:**
- Create: `LICENSE`, `Core/Sources/BMWCodingCore/Provider.swift`, `Core/Tests/BMWCodingCoreTests/ProviderTests.swift`
- Modify: `Core/Sources/BMWCodingCore/Conversation.swift`, `Core/Tests/BMWCodingCoreTests/ConversationTests.swift`, `App/AIFlow.swift` (only `AISettings`)

**Interfaces:**
- Produces: `public enum Provider: String, Codable, Equatable, Sendable, CaseIterable { case anthropic, openai }` with `public var displayName: String` (`Anthropic`, `OpenAI`); `Conversation.provider: Provider`; `TurnRecord.provider: Provider`; `ConversationStore.load(vin:provider:)`, `save(_:)`, `delete(vin:provider:)`, `deleteAll()`; `AISettings.provider`, `AISettings.openAIModel: String?`.

- [ ] **Step 1: Write the failing tests**

In `ProviderTests.swift`:

```swift
@Test func providersHaveNamesAndRawValues() {
    #expect(Provider.anthropic.rawValue == "anthropic" && Provider.openai.rawValue == "openai")
    #expect(Provider.anthropic.displayName == "Anthropic" && Provider.openai.displayName == "OpenAI")
    #expect(Provider.allCases == [.anthropic, .openai])
}
```

In `ConversationTests.swift`:

```swift
@Test func conversationsAreStoredPerProvider() throws {
    let store = ConversationStore(directory: temporaryFolder())
    let claude = Conversation(vin: "WBY73AW04RFFAKE19", started: .now, model: "claude-opus-5-5", carContext: "{}")
    var gpt = Conversation(vin: "WBY73AW04RFFAKE19", started: .now, model: "gpt-6.1-sol", carContext: "{}", provider: .openai)
    gpt.messages = [.object(["type": .string("message"), "role": .string("user"), "content": .string("hi")])]
    try store.save(claude)
    try store.save(gpt)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic)?.provider == .anthropic)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .openai)?.messages == gpt.messages)
    try store.delete(vin: "WBY73AW04RFFAKE19", provider: .openai)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .openai) == nil)
    #expect(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic) != nil)
}

@Test func aStageOneConversationFileLoadsAsAnthropics() throws {
    let folder = temporaryFolder()
    let store = ConversationStore(directory: folder)
    let conversations = folder.appendingPathComponent("Conversations")
    try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
    let old = """
        {"carContext":"{}","messages":[],"model":"claude-opus-5-5","started":"2026-10-27T10:00:00Z",\
        "turns":[{"messageIndex":0,"model":"claude-opus-5-5","refused":false,"rounds":1,"stopped":false,\
        "stoppedAtRoundCap":false,"truncated":false,"usage":{"cacheCreationInputTokens":0,"cacheReadInputTokens":0,\
        "inputTokens":1,"outputTokens":1,"webFetchRequests":0,"webSearchRequests":0}}],"vin":"WBY73AW04RFFAKE19"}
        """
    try Data(old.utf8).write(to: conversations.appendingPathComponent("WBY73AW04RFFAKE19.json"))
    let loaded = try #require(store.load(vin: "WBY73AW04RFFAKE19", provider: .anthropic))
    #expect(loaded.provider == .anthropic && loaded.turns.first?.provider == .anthropic)
    try store.save(loaded)  // moves to the per-provider file
    #expect(!FileManager.default.fileExists(atPath: conversations.appendingPathComponent("WBY73AW04RFFAKE19.json").path))
    #expect(FileManager.default.fileExists(atPath: conversations.appendingPathComponent("WBY73AW04RFFAKE19-anthropic.json").path))
}
```

`temporaryFolder()` is the helper the file already uses for the store tests (a fresh folder under `FileManager.default.temporaryDirectory`); add it if the existing tests build the folder inline.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter 'ProviderTests|ConversationTests'`
Expected: compile errors `cannot find 'Provider' in scope`, `extra argument 'provider' in call`.

- [ ] **Step 3: Implement**

`Provider.swift`: the enum above, `nonisolated` like the package's other value types.

`Conversation.swift`:
- `Conversation` gains `public var provider: Provider` after `model`; the init gains `provider: Provider = .anthropic` as its last parameter; a custom `init(from:)` decodes it with `decodeIfPresent` defaulting to `.anthropic` (keep the other fields' decoding synthesized by decoding them explicitly in the same init; the encoder stays synthesized).
- `TurnRecord` gains `public var provider: Provider` after `model` and `public var webSearchDropped: Bool` after `activity` (the turn ran without web search because the model refused it; Task 7 sets it), init parameters `provider: Provider = .anthropic` and `webSearchDropped: Bool = false`, both `decodeIfPresent` in its `init(from:)` (the flag defaulting to `false`).
- `ConversationStore`: the file is `Conversations/<vin>-<provider.rawValue>.json`. `load(vin:provider:)` reads that file; for `.anthropic`, when it is missing, it reads the stage-1 file `Conversations/<vin>.json` instead. `save` writes the per-provider file and then removes `Conversations/<vin>.json` if it exists and the conversation is Anthropic's (ignoring a removal error). `delete(vin:provider:)` removes the per-provider file and, for `.anthropic`, the stage-1 file too. `deleteAll()` is unchanged.

`AIFlow.swift`, `AISettings` only: `var provider = Provider.anthropic`, `var openAIModel: String?` (the picked OpenAI model, nil until the list was fetched), both decoded with `decodeIfPresent` through a custom `init(from:)` so a saved stage-1 record still loads (the `load()` fallback would otherwise silently reset the settings). `model` stays the Anthropic model.

`LICENSE`: the MIT License text with `Copyright (c) 2026 Scott Brant`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: all pass (202 before this task, plus the three new ones).

- [ ] **Step 5: Build the app and commit**

Run: `make project && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build`
Expected: exit 0 (the settings change compiles; nothing else in the app changes yet).

```bash
git add LICENSE Core/Sources/BMWCodingCore/Provider.swift Core/Sources/BMWCodingCore/Conversation.swift Core/Tests/BMWCodingCoreTests/ProviderTests.swift Core/Tests/BMWCodingCoreTests/ConversationTests.swift App/AIFlow.swift
git commit -m "Provider: conversations and settings per provider, MIT license"
```

---

### Task 2: The Responses API stream

**Files:**
- Create: `Core/Sources/BMWCodingCore/OpenAIAPI.swift`, `Core/Tests/BMWCodingCoreTests/OpenAIAPITests.swift`
- Modify: `Core/Sources/BMWCodingCore/ClaudeAPI.swift` (`Usage`), `Core/Tests/BMWCodingCoreTests/FakeTransport.swift` (fixtures)

**Interfaces:**
- Consumes: `SSEParser`, `SSEEvent`, `StreamUpdate`, `Usage`, `JSON`.
- Produces:
  - `Usage.reasoningTokens: Int` (new field, memberwise init parameter after `webFetchRequests`, default 0 in `Usage.init(_ json:)`, summed by `+`, decoded with `decodeIfPresent` so stage-1 files load).
  - `public struct ResponsesMessage: Equatable, Sendable { public var id: String; public var model: String; public var output: [JSON]; public var status: String; public var incompleteReason: String?; public var usage: Usage }` — `output` holds the completed output items exactly as `response.completed` carried them.
  - `public enum OpenAIError: Error, Equatable { case api(status: Int?, code: String, message: String, param: String?); case planLimit(code: String, message: String, usage: Usage); case unauthorized; case badToolInput(String); case network(String) }`.
  - `public struct ResponsesAssembler { public init(); public mutating func apply(_ event: SSEEvent) throws -> StreamUpdate?; public func message() -> ResponsesMessage }`.

- [ ] **Step 1: Add the fixtures to `FakeTransport.swift`**

```swift
/// One Responses stream: `response.created`, the events of `items`, and the terminal event with the items as the
/// response's `output` and the usage.
func responsesStream(_ items: [ResponsesItemFixture], end: String = "completed", input: Int = 100, cached: Int = 0,
                     output: Int = 10, reasoning: Int = 0, incompleteReason: String? = nil) -> String {
    let outputs = items.map(\.json).joined(separator: ",")
    let response = { (status: String) in
        #"{"id":"resp_1","object":"response","model":"gpt-6.1-sol","status":"\#(status)","output":[\#(outputs)],"incomplete_details":\#(incompleteReason.map { #"{"reason":"\#($0)"}"# } ?? "null"),"usage":{"input_tokens":\#(input),"input_tokens_details":{"cached_tokens":\#(cached)},"output_tokens":\#(output),"output_tokens_details":{"reasoning_tokens":\#(reasoning)},"total_tokens":\#(input + output)}}"#
    }
    return [event("response.created", #"{"type":"response.created","sequence_number":0,"response":\#(response("in_progress"))}"#),
            items.map(\.events).joined(),
            event("response.\(end)", #"{"type":"response.\#(end)","sequence_number":99,"response":\#(response(end))}"#)].joined()
}

/// A Responses stream that fails after `items` with `code` and `message` in `response.failed`.
func responsesFailure(_ items: [ResponsesItemFixture], code: String, message: String) -> String {
    let outputs = items.map(\.json).joined(separator: ",")
    return [event("response.created", #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","object":"response","model":"gpt-6.1-sol","status":"in_progress","output":[],"usage":null}}"#),
            items.map(\.events).joined(),
            event("response.failed", #"{"type":"response.failed","sequence_number":99,"response":{"id":"resp_1","object":"response","model":"gpt-6.1-sol","status":"failed","output":[\#(outputs)],"error":{"code":\#(literal(code)),"message":\#(literal(message))},"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":0},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":105}}}"#)].joined()
}

/// An item of a Responses stream: its events, and its JSON as it appears in the response's output.
struct ResponsesItemFixture { var events: String; var json: String }

/// An assistant message item with one output_text part, `text`, and the `url_citation` annotations given.
func textItem(_ index: Int, _ text: String, citations: [(url: String, title: String)] = []) -> ResponsesItemFixture {
    let id = "msg_\(index)"
    let annotations = citations.map { #"{"type":"url_citation","url":\#(literal($0.url)),"title":\#(literal($0.title)),"start_index":0,"end_index":1}"# }.joined(separator: ",")
    let item = #"{"id":"\#(id)","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":\#(literal(text)),"annotations":[\#(annotations)]}]}"#
    let events = [
        event("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":\#(index),"item":{"id":"\#(id)","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
        event("response.content_part.added", #"{"type":"response.content_part.added","sequence_number":2,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
        event("response.output_text.delta", #"{"type":"response.output_text.delta","sequence_number":3,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"delta":\#(literal(text)),"logprobs":[]}"#),
    ] + citations.map { event("response.output_text.annotation.added", #"{"type":"response.output_text.annotation.added","sequence_number":4,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"annotation_index":0,"annotation":{"type":"url_citation","url":\#(literal($0.url)),"title":\#(literal($0.title)),"start_index":0,"end_index":1}}"#) } + [
        event("response.output_text.done", #"{"type":"response.output_text.done","sequence_number":5,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"text":\#(literal(text)),"logprobs":[]}"#),
        event("response.content_part.done", #"{"type":"response.content_part.done","sequence_number":6,"item_id":"\#(id)","output_index":\#(index),"content_index":0,"part":{"type":"output_text","text":\#(literal(text)),"annotations":[\#(annotations)]}}"#),
        event("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":7,"output_index":\#(index),"item":\#(item)}"#),
    ]
    return ResponsesItemFixture(events: events.joined(), json: item)
}

/// A function call item of the `car` namespace whose arguments arrive as the JSON text `arguments`.
func functionCallItem(_ index: Int, callId: String, name: String, arguments: String) -> ResponsesItemFixture {
    let id = "fc_\(index)"
    let item = #"{"id":"\#(id)","type":"function_call","status":"completed","namespace":"car","name":\#(literal(name)),"call_id":\#(literal(callId)),"arguments":\#(literal(arguments))}"#
    let events = [
        event("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":\#(index),"item":{"id":"\#(id)","type":"function_call","status":"in_progress","namespace":"car","name":\#(literal(name)),"call_id":\#(literal(callId)),"arguments":""}}"#),
        event("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","sequence_number":2,"item_id":"\#(id)","output_index":\#(index),"delta":\#(literal(arguments))}"#),
        event("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","sequence_number":3,"item_id":"\#(id)","output_index":\#(index),"arguments":\#(literal(arguments))}"#),
        event("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":4,"output_index":\#(index),"item":\#(item)}"#),
    ]
    return ResponsesItemFixture(events: events.joined(), json: item)
}

/// A reasoning item with encrypted content, as `include: ["reasoning.encrypted_content"]` returns it.
func reasoningItem(_ index: Int) -> ResponsesItemFixture {
    let item = #"{"id":"rs_\#(index)","type":"reasoning","summary":[],"encrypted_content":"gAAAA-opaque"}"#
    let events = [
        event("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":\#(index),"item":{"id":"rs_\#(index)","type":"reasoning","summary":[]}}"#),
        event("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":2,"output_index":\#(index),"item":\#(item)}"#),
    ]
    return ResponsesItemFixture(events: events.joined(), json: item)
}

/// A completed web search call for `query`.
func webSearchItem(_ index: Int, query: String) -> ResponsesItemFixture {
    let item = #"{"id":"ws_\#(index)","type":"web_search_call","status":"completed","action":{"type":"search","query":\#(literal(query))}}"#
    let events = [
        event("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":\#(index),"item":{"id":"ws_\#(index)","type":"web_search_call","status":"in_progress","action":{"type":"search","query":\#(literal(query))}}}"#),
        event("response.web_search_call.in_progress", #"{"type":"response.web_search_call.in_progress","sequence_number":2,"item_id":"ws_\#(index)","output_index":\#(index)}"#),
        event("response.web_search_call.searching", #"{"type":"response.web_search_call.searching","sequence_number":3,"item_id":"ws_\#(index)","output_index":\#(index)}"#),
        event("response.web_search_call.completed", #"{"type":"response.web_search_call.completed","sequence_number":4,"item_id":"ws_\#(index)","output_index":\#(index)}"#),
        event("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":5,"output_index":\#(index),"item":\#(item)}"#),
    ]
    return ResponsesItemFixture(events: events.joined(), json: item)
}
```

`event` and `literal` are the file's existing private helpers; make them `fileprivate` is enough since the fixtures live in the same file.

- [ ] **Step 2: Write the failing tests** in `OpenAIAPITests.swift`

```swift
import Foundation
import Testing
@testable import BMWCodingCore

/// Feeds a stream's lines through the parser and assembler, collecting the updates.
func assemble(_ stream: String) throws -> (updates: [StreamUpdate], message: ResponsesMessage) {
    var parser = SSEParser(), assembler = ResponsesAssembler(), updates: [StreamUpdate] = []
    for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
        if let event = parser.feed(String(line)), let update = try assembler.apply(event) { updates.append(update) }
    }
    return (updates, assembler.message())
}

@Test func textStreamsAndTheMessageCarriesItsItemsAndUsage() throws {
    let (updates, message) = try assemble(responsesStream([reasoningItem(0), textItem(1, "Hello owner", citations: [("https://a.example/p", "Page")])], input: 300, cached: 250, output: 12, reasoning: 7))
    #expect(updates.first == .block(try JSON.parse(Data(reasoningItem(0).json.utf8))))
    #expect(updates.contains(.text("Hello owner")))
    #expect(updates.last == .finished)
    #expect(message.status == "completed" && message.output.count == 2)
    #expect(message.output[1]["content"]?.array?[0]["annotations"]?.array?[0]["url"]?.string == "https://a.example/p")
    #expect(message.usage == Usage(inputTokens: 300, outputTokens: 12, cacheCreationInputTokens: 0, cacheReadInputTokens: 250, webSearchRequests: 0, webFetchRequests: 0, reasoningTokens: 7))
}

@Test func aFunctionCallArrivesWholeAndASearchCounts() throws {
    let (updates, message) = try assemble(responsesStream([webSearchItem(0, query: "B1F3E BMW"), functionCallItem(1, callId: "call_1", name: "read_faults", arguments: #"{"module":"40"}"#)]))
    let call = try JSON.parse(Data(functionCallItem(1, callId: "call_1", name: "read_faults", arguments: #"{"module":"40"}"#).json.utf8))
    #expect(updates.contains(.block(call)))
    #expect(message.usage.webSearchRequests == 1)
    #expect(message.output[1]["arguments"]?.string == #"{"module":"40"}"#)
}

@Test func anIncompleteResponseKeepsItsReasonAndText() throws {
    let (_, message) = try assemble(responsesStream([textItem(0, "Half an")], end: "incomplete", incompleteReason: "max_output_tokens"))
    #expect(message.status == "incomplete" && message.incompleteReason == "max_output_tokens")
    #expect(message.output.count == 1)
}

@Test func aFailedResponseThrowsItsCode() throws {
    let planLimit = responsesFailure([textItem(0, "Looking")], code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached")
    #expect(throws: OpenAIError.planLimit(code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached", usage: Usage(inputTokens: 100, outputTokens: 5, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, webSearchRequests: 0, webFetchRequests: 0, reasoningTokens: 0))) { try assemble(planLimit) }
    let other = responsesFailure([], code: "server_error", message: "boom")
    #expect(throws: OpenAIError.api(status: nil, code: "server_error", message: "boom", param: nil)) { try assemble(other) }
}

@Test func anErrorEventThrowsAndAnUnreadableArgumentIsReportedAtTheEnd() throws {
    let errorEvent = "event: error\ndata: {\"type\":\"error\",\"sequence_number\":1,\"code\":\"invalid_request\",\"message\":\"bad\",\"param\":null}\n\n"
    #expect(throws: OpenAIError.api(status: nil, code: "invalid_request", message: "bad", param: nil)) { try assemble(errorEvent) }
    let cutCall = responsesStream([functionCallItem(0, callId: "c", name: "read_faults", arguments: #"{"module":"4"#)])
    #expect(throws: OpenAIError.badToolInput(#"{"module":"4"#)) { try assemble(cutCall) }
    let cutByLimit = responsesStream([functionCallItem(0, callId: "c", name: "read_faults", arguments: #"{"module":"4"#)], end: "incomplete", incompleteReason: "max_output_tokens")
    #expect(try assemble(cutByLimit).message.output[0]["arguments"]?.string == "{}")
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Core && swift test --filter OpenAIAPITests`
Expected: compile errors `cannot find 'ResponsesAssembler' in scope`, `extra argument 'reasoningTokens'`.

- [ ] **Step 4: Implement `OpenAIAPI.swift` and the `Usage` field**

`Usage`: add `reasoningTokens` as described; `update(from:)` also reads `input_tokens_details.cached_tokens` into `cacheReadInputTokens` and `output_tokens_details.reasoning_tokens` into `reasoningTokens` when those keys exist, so one `Usage` reads both APIs' usage objects.

`ResponsesAssembler.apply(_ event: SSEEvent) throws -> StreamUpdate?`, keyed on the event's `data` JSON `type`:
- `response.created`, `response.in_progress`, `response.content_part.*`, `response.output_text.done`, `response.function_call_arguments.done`, `response.web_search_call.*`, `response.reasoning_*`, and any unknown type: nothing (`nil`).
- `response.output_text.delta`: `.text(delta)`.
- `response.output_text.annotation.added`: nothing (the finished item carries its annotations).
- `response.output_item.added`: remember the item under its `output_index`; nothing returned.
- `response.function_call_arguments.delta`: nothing (the `done` item carries the whole text).
- `response.output_item.done`: the finished item, stored under its index, is returned as `.block(item)`. A `function_call` item whose `arguments` is not a JSON object has its `arguments` replaced by `"{}"` in the stored item and the raw text remembered, as the Claude assembler does.
- `response.completed` and `response.incomplete`: take the `response`'s `id`, `model`, `status`, `incomplete_details.reason`, `output` (the items, in order, replacing what was collected — they are the same items, complete) and `usage` (through `Usage.init(_:)`, then `webSearchRequests` set to the count of `web_search_call` items in the output), then return `.finished`; before that, if an unreadable argument was remembered and the status is `completed`, throw `OpenAIError.badToolInput(text)`.
- `response.failed`: throw `.planLimit(code:message:usage:)` with the usage the failed response carries (`.zero` when it has none) when `response.error.code` is `subscription_sharing_usage_limit_exceeded` or `subscription_sharing_usage_unavailable`, else `.api(status: nil, code:message:param: nil)`.
- `error`: throw `.api(status: nil, code: code ?? "error", message:, param:)`.

`message()` returns the `ResponsesMessage` as assembled so far.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/BMWCodingCore/OpenAIAPI.swift Core/Sources/BMWCodingCore/ClaudeAPI.swift Core/Tests/BMWCodingCoreTests/OpenAIAPITests.swift Core/Tests/BMWCodingCoreTests/FakeTransport.swift
git commit -m "OpenAI: Responses stream assembly"
```

---

### Task 3: The OpenAI client: request body, retries, tool loop

**Files:**
- Create: `Core/Sources/BMWCodingCore/OpenAIClient.swift`, `Core/Tests/BMWCodingCoreTests/OpenAIClientTests.swift`
- Modify: `Core/Sources/BMWCodingCore/ClaudeClient.swift` (`URLSessionTransport(url:)`, `Turn.webSearchDropped`)

**Interfaces:**
- Consumes: `Transport`, `TransportResponse`, `SSEParser`, `ResponsesAssembler`, `ResponsesMessage`, `OpenAIError`, `ToolCall`, `ToolResult`, `Turn`, `Mechanic.tools` (the Anthropic-shaped declarations), `Log`.
- Produces:
  - `URLSessionTransport.init(url: URL = URL(string: "https://api.anthropic.com/v1/messages")!)`; the stored `url` is what `post` requests.
  - `Turn.webSearchDropped: Bool = false` (a new last property with a default, so the memberwise init still takes the five old arguments).
  - `public struct OpenAIRequest: Equatable, Sendable { public var model: String; public var effort: String; public var instructions: String; public var tools: [JSON]; public var webSearch: Bool; public var input: [JSON]; public var toolChoiceNone: Bool = false }`.
  - `public final class OpenAIClient` with `public static let roundCap = ClaudeClient.roundCap`, `public static let roundCapResult = ClaudeClient.roundCapResult`, `public static let noWebSentence = "Web search is not available in this conversation: when a question needs a lookup, say so instead of guessing."`, `public private(set) var webSearchUnavailable: Set<String>` (models), `public init(transport: any Transport, accessToken: String, log: Log, webSearchUnavailable: Set<String> = [], sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) })` (the set is the models already known to refuse web search, which the app carries from one client to the next), `public static func body(for request: OpenAIRequest) -> JSON`, `public func send(_ request: OpenAIRequest, onUpdate: (StreamUpdate) -> Void) async throws -> ResponsesMessage`, and `run` with the `ModelClient` signature of Task 4 (`messages` are Responses input items; `system` are the text blocks `Mechanic.systemPrompt` returns, joined with a blank line into `instructions`).

- [ ] **Step 1: Write the failing tests** in `OpenAIClientTests.swift`

```swift
import Foundation
import Testing
@testable import BMWCodingCore

func ownerItem(_ text: String) -> JSON {
    .object(["type": .string("message"), "role": .string("user"), "content": .array([.object(["type": .string("input_text"), "text": .string(text)])])])
}
func openAIRequest(_ items: [JSON] = [ownerItem("q")], web: Bool = true) -> OpenAIRequest {
    OpenAIRequest(model: "gpt-6.1-sol", effort: "medium", instructions: "rules", tools: Mechanic.tools, webSearch: web, input: items)
}
func errorBody(_ code: String, _ message: String, param: String? = nil) -> String {
    #"{"error":{"type":"invalid_request_error","code":\#(literalJSON(code)),"message":\#(literalJSON(message)),"param":\#(param.map(literalJSON) ?? "null")}}"#
}
func literalJSON(_ text: String) -> String { String(decoding: JSON.string(text).encoded(), as: UTF8.self) }

@Test func bodyAndHeadersFollowTheSignInWithChatGPTRules() async throws {
    let transport = FakeTransport([(200, [:], responsesStream([textItem(0, "hi")]))])
    let client = OpenAIClient(transport: transport, accessToken: "eyJ-access", log: Log())
    _ = try await client.send(openAIRequest()) { _ in }
    let call = try #require(transport.calls.first)
    #expect(call.headers["authorization"] == "Bearer eyJ-access" && call.headers["x-api-key"] == nil)
    #expect(call.headers["content-type"] == "application/json" && call.headers["accept"] == "text/event-stream")
    let body = call.body
    #expect(body["model"]?.string == "gpt-6.1-sol" && body["instructions"]?.string == "rules")
    #expect(body["stream"]?.bool == true && body["store"]?.bool == false)
    #expect(body["reasoning"]?["effort"]?.string == "medium")
    #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
    #expect(body["input"]?.array?.count == 1 && body["input"]?.array?[0]["role"]?.string == "user")
    for key in ["max_output_tokens", "temperature", "top_p", "truncation", "metadata", "user", "safety_identifier", "previous_response_id", "tool_choice", "prompt_cache_retention", "background", "conversation", "max_tool_calls"] {
        #expect(body[key] == nil, "\(key) must be omitted")
    }
    let tools = try #require(body["tools"]?.array)
    #expect(tools.count == 2)
    #expect(tools[0]["type"]?.string == "namespace" && tools[0]["name"]?.string == "car")
    let functions = try #require(tools[0]["tools"]?.array)
    #expect(functions.count == 6 && functions.allSatisfy { $0["type"]?.string == "function" && $0["strict"]?.bool == true })
    #expect(functions[1]["name"]?.string == "read_faults")
    #expect(functions[1]["parameters"] == Mechanic.tools[1]["input_schema"] && functions[1]["input_schema"] == nil)
    #expect(tools[1] == .object(["type": .string("web_search")]))
    #expect(OpenAIClient.body(for: openAIRequest(web: false))["tools"]?.array?.count == 1)
    var capped = openAIRequest(); capped.toolChoiceNone = true
    #expect(OpenAIClient.body(for: capped)["tool_choice"]?.string == "none")
}

@Test func retriesServerErrorsAndStopsAtThePlanLimit() async throws {
    var waits: [Duration] = []
    let transport = FakeTransport([
        (500, [:], errorBody("server_error", "boom")), (503, [:], errorBody("subscription_sharing_usage_unavailable", "later")),
        (200, [:], responsesStream([textItem(0, "ok")])),
    ])
    let client = OpenAIClient(transport: transport, accessToken: "t", log: Log()) { waits.append($0) }
    let message = try await client.send(openAIRequest()) { _ in }
    #expect(message.output.count == 1 && transport.calls.count == 3 && waits == [.seconds(1), .seconds(2)])

    let limited = FakeTransport([(429, ["retry-after": "20"], errorBody("subscription_sharing_usage_limit_exceeded", "Usage limit reached"))])
    let limitedClient = OpenAIClient(transport: limited, accessToken: "t", log: Log())
    await #expect(throws: OpenAIError.planLimit(code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached", usage: .zero)) {
        try await limitedClient.send(openAIRequest()) { _ in }
    }
    #expect(limited.calls.count == 1)
}

@Test func unauthorizedIsNotRetriedAndTheTokenIsNeverLogged() async throws {
    let log = Log()
    let transport = FakeTransport([(401, [:], errorBody("invalid_token", "The token is invalid"))])
    let client = OpenAIClient(transport: transport, accessToken: "eyJ-secret-token", log: log)
    await #expect(throws: OpenAIError.unauthorized) { try await client.send(openAIRequest()) { _ in } }
    #expect(transport.calls.count == 1)
    #expect(log.entries.contains { $0.text == "ai: error 401 invalid_token: The token is invalid" })
    #expect(!log.entries.contains { $0.text.contains("eyJ-secret-token") })
}

@Test func theToolLoopRunsCallsAndKeepsEveryItem() async throws {
    let transport = FakeTransport([
        (200, [:], responsesStream([reasoningItem(0), functionCallItem(1, callId: "call_1", name: "read_faults", arguments: #"{"module":"40"}"#)], input: 100, output: 20)),
        (200, [:], responsesStream([textItem(0, "No faults in BDC")], input: 300, output: 15)),
    ])
    let client = OpenAIClient(transport: transport, accessToken: "t", log: Log())
    var items = [ownerItem("q")], calls: [ToolCall] = [], usages: [Usage] = []
    let turn = try await client.run(messages: &items, system: [.object(["type": .string("text"), "text": .string("rules")]), .object(["type": .string("text"), "text": .string("car")])], tools: Mechanic.tools, model: "gpt-6.1-sol", effort: "high",
        runTool: { call in calls.append(call); return ToolResult("none stored") }, onUpdate: { _ in }, onUsage: { usages.append($0) })
    #expect(calls == [ToolCall(id: "call_1", name: "read_faults", input: .object(["module": .string("40")]))])
    #expect(turn.rounds == 1 && turn.usage.inputTokens == 400 && usages.count == 2)
    #expect(items.count == 5)  // owner, reasoning, function_call, function_call_output, assistant message
    #expect(items[1]["type"]?.string == "reasoning" && items[1]["encrypted_content"]?.string == "gAAAA-opaque")
    #expect(items[3] == .object(["type": .string("function_call_output"), "call_id": .string("call_1"), "namespace": .string("car"), "name": .string("read_faults"), "output": .string("none stored")]))
    #expect(items[4]["type"]?.string == "message" && items[4]["role"]?.string == "assistant")
    let second = try #require(transport.calls.last)
    #expect(second.body["instructions"]?.string == "rules\n\ncar")
    #expect(second.body["input"]?.array?.count == 4)  // the whole history, reasoning included, no previous_response_id
}

@Test func aFailingToolAnswersWithAnErrorOutput() async throws {
    let transport = FakeTransport([
        (200, [:], responsesStream([functionCallItem(0, callId: "c", name: "read_value", arguments: #"{"module":"40","did":"zz"}"#)])),
        (200, [:], responsesStream([textItem(0, "Could not read")])),
    ])
    var items = [ownerItem("q")]
    _ = try await OpenAIClient(transport: transport, accessToken: "t", log: Log()).run(messages: &items, system: [], tools: Mechanic.tools, model: "m", effort: "low",
        runTool: { _ in ToolResult("did must be four hex digits", isError: true) }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(items[2]["output"]?.string == "Error: did must be four hex digits")
}

@Test func stopsAtTheRoundCapWithToolChoiceNone() async throws {
    var script: [(status: Int, headers: [String: String], text: String)] = []
    for round in 0...OpenAIClient.roundCap { script.append((200, [:], responsesStream([functionCallItem(0, callId: "c\(round)", name: "get_vehicle", arguments: "{}")]))) }
    script.append((200, [:], responsesStream([textItem(0, "Here is what I have")])))
    let transport = FakeTransport(script)
    var items = [ownerItem("q")], ran = 0
    let turn = try await OpenAIClient(transport: transport, accessToken: "t", log: Log()).run(messages: &items, system: [], tools: Mechanic.tools, model: "m", effort: "low",
        runTool: { _ in ran += 1; return ToolResult("{}") }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(ran == OpenAIClient.roundCap && turn.stoppedAtRoundCap && turn.rounds == OpenAIClient.roundCap + 1)
    #expect(transport.calls.last?.body["tool_choice"]?.string == "none")
    #expect(items[items.count - 2]["output"]?.string == "Error: " + OpenAIClient.roundCapResult)
}

@Test func anIncompleteAnswerKeepsOnlyItsTextAndRunsNothing() async throws {
    let transport = FakeTransport([(200, [:], responsesStream([textItem(0, "Half an"), functionCallItem(1, callId: "c", name: "get_vehicle", arguments: "{}")], end: "incomplete", incompleteReason: "max_output_tokens"))])
    var items = [ownerItem("q")], ran = false
    let turn = try await OpenAIClient(transport: transport, accessToken: "t", log: Log()).run(messages: &items, system: [], tools: Mechanic.tools, model: "m", effort: "low",
        runTool: { _ in ran = true; return ToolResult("") }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(!ran && turn.truncated && items.count == 2 && items[1]["type"]?.string == "message")
}

@Test func aPlanLimitMidTurnLeavesTheConversationAsItWasAndReportsTheUsage() async throws {
    let transport = FakeTransport([
        (200, [:], responsesStream([functionCallItem(0, callId: "c", name: "get_vehicle", arguments: "{}")], input: 100, output: 20)),
        (200, [:], responsesFailure([textItem(0, "Looking")], code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached")),
    ])
    var items = [ownerItem("q")], usages: [Usage] = []
    let client = OpenAIClient(transport: transport, accessToken: "t", log: Log())
    await #expect(throws: OpenAIError.planLimit(code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached", usage: Usage(inputTokens: 100, outputTokens: 5, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, webSearchRequests: 0, webFetchRequests: 0, reasoningTokens: 0))) {
        try await client.run(messages: &items, system: [], tools: Mechanic.tools, model: "m", effort: "low", runTool: { _ in ToolResult("{}") }, onUpdate: { _ in }, onUsage: { usages.append($0) })
    }
    #expect(items == [ownerItem("q")] && usages.map(\.outputTokens) == [20, 5])
}

@Test func aModelWithoutWebSearchGetsTheRequestAgainWithoutIt() async throws {
    let log = Log()
    let transport = FakeTransport([
        (400, [:], errorBody("subscription_sharing_unsupported_capability", "web_search is not available for this model", param: "tools[1]")),
        (200, [:], responsesStream([textItem(0, "From the car data")])),
        (200, [:], responsesStream([textItem(0, "Still from the car data")])),
    ])
    let client = OpenAIClient(transport: transport, accessToken: "t", log: log)
    var items = [ownerItem("q")]
    let turn = try await client.run(messages: &items, system: [.object(["type": .string("text"), "text": .string("rules")])], tools: Mechanic.tools, model: "gpt-6.1-sol", effort: "low", runTool: { _ in ToolResult("") }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(turn.webSearchDropped && client.webSearchUnavailable == ["gpt-6.1-sol"])
    #expect(transport.calls[0].body["tools"]?.array?.count == 2 && transport.calls[1].body["tools"]?.array?.count == 1)
    #expect(transport.calls[1].body["instructions"]?.string == "rules\n\n" + OpenAIClient.noWebSentence)
    #expect(log.entries.contains { $0.text == "ai: web search unavailable on gpt-6.1-sol, asking again without it" })
    items.append(ownerItem("more"))
    let later = try await client.run(messages: &items, system: [.object(["type": .string("text"), "text": .string("rules")])], tools: Mechanic.tools, model: "gpt-6.1-sol", effort: "low", runTool: { _ in ToolResult("") }, onUpdate: { _ in }, onUsage: { _ in })
    #expect(!later.webSearchDropped && transport.calls[2].body["tools"]?.array?.count == 1)

    let other = FakeTransport([(400, [:], errorBody("subscription_sharing_unsupported_capability", "model not available", param: "model"))])
    var again = [ownerItem("q")]
    await #expect(throws: OpenAIError.api(status: 400, code: "subscription_sharing_unsupported_capability", message: "model not available", param: "model")) {
        try await OpenAIClient(transport: other, accessToken: "t", log: Log()).run(messages: &again, system: [], tools: Mechanic.tools, model: "m", effort: "low", runTool: { _ in ToolResult("") }, onUpdate: { _ in }, onUsage: { _ in })
    }
    #expect(other.calls.count == 1)
}

@Test func aStreamThatEndsBeforeCompletionThrowsNetwork() async throws {
    let cut = "event: response.created\ndata: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"r\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
    let transport = FakeTransport([(200, [:], cut)])
    await #expect(throws: OpenAIError.network("the stream ended before response.completed")) {
        try await OpenAIClient(transport: transport, accessToken: "t", log: Log()).send(openAIRequest()) { _ in }
    }
}
```

The `Task 2` test `aFailedResponseThrowsItsCode` expects `.planLimit(code:message:usage:)`: the usage the failed response carried (`Usage(inputTokens: 100, outputTokens: 5, …)`), as the fixture `responsesFailure` writes it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter OpenAIClientTests`
Expected: compile errors `cannot find 'OpenAIClient' in scope`, `cannot find 'OpenAIRequest' in scope`.

- [ ] **Step 3: Implement**

`ClaudeClient.swift`: `URLSessionTransport` stores `url` from `init(url:)` (default the Messages endpoint) and posts to it; `Turn` gains `public var webSearchDropped = false`.

`OpenAIClient.body(for:)`: `model`, `instructions`, `input`, `stream: true`, `store: false`, `reasoning: {"effort": effort}`, `include: ["reasoning.encrypted_content"]`, `tools`: first `{"type": "namespace", "name": "car", "description": "The connected car and the app's data about it, read through the app", "tools": [...]}` holding every entry of `request.tools` that has an `input_schema`, rewritten as `{"type": "function", "name", "description", "parameters": <input_schema>, "strict": true}` in order; then `{"type": "web_search"}` when `request.webSearch`; `tool_choice: "none"` when `toolChoiceNone`. Nothing else.

`send`: as `ClaudeClient.send`, with these differences. Headers `authorization: Bearer <token>`, `content-type: application/json`, `accept: text/event-stream`. Log `ai: request <model> effort <effort>, <n> items, <t> tools` per try and, on success, `ai: <status> · in <input> · cached <cached> · out <output> · reasoning <reasoning> · searches <n>`. Retried: status 500, 502, 503 and 429 unless the 429 body's `error.code` is `subscription_sharing_usage_limit_exceeded`, which throws `.planLimit(code:message:usage: .zero)` at once; `.planLimit` with code `subscription_sharing_usage_unavailable` thrown by the assembler mid-stream is retried too; three tries, 1 s then 2 s, a 429's integer `retry-after` instead (at most 30 s). Status 401 throws `.unauthorized` at once. Any other non-2xx throws `.api(status:code:message:param:)` from the body's `error` object (`code: "http_<status>"` and the first 200 characters when the body is not that). A stream that ends before `.finished` throws `.network("the stream ended before response.completed")`; a `URLError` arrives already mapped by the transport (`ClaudeError.network` → map to `OpenAIError.network` with the same text). Thrown errors are logged once: `ai: error <status|-> <code>: <message>`, `ai: plan limit <code>: <message>`, `ai: error 401 <code>: <message>`, `ai: network error: <message>`. The token never appears in a note.

`run`: instructions are the `system` blocks' `text` values joined with `"\n\n"`, plus `"\n\n" + noWebSentence` when web search is off for this model. The loop, per round: build the request with `webSearch: !webSearchUnavailable.contains(model)`; `send`; `onUsage(message.usage)` and add it to the turn. On `.api(status: 400, code: "subscription_sharing_unsupported_capability", …)` whose `param` or `message` contains `web_search` while the request had web search on: insert the model into `webSearchUnavailable`, log `ai: web search unavailable on <model>, asking again without it`, set `turn.webSearchDropped = true` and repeat the round without it (the instructions gain the sentence); any other error propagates. On `.planLimit`, `onUsage` with the usage it carries, then rethrow (the turn's `messages` are untouched, as on any throw). Then: when `status == "incomplete"`, append only the output's `message` items and set `truncated`, break; when the output's last `message` item has a `refusal` part, append the message items, set `refused`, break; otherwise append every output item as it came (reasoning items with their `encrypted_content`, `web_search_call` items, `message` items, `function_call` items). Then the calls: `function_call` items in order; `rounds += 1`; past `roundCap` every call gets `{"type": "function_call_output", "call_id", "namespace": "car", "name", "output": "Error: " + roundCapResult}` and `toolChoiceNone` is set for the next request; otherwise each call's `arguments` is parsed (`JSON.parse`; not an object → the result `ToolResult("tool input was not an object", isError: true)` without running), run through `runTool` as `ToolCall(id: call_id, name:, input:)`, and answered with a `function_call_output` whose `output` is the result's content, prefixed `Error: ` when `isError`. No calls and status `completed`: break. After `toolChoiceNone` the next answer ends the turn with `stoppedAtRoundCap`. `messages` takes the conversation only when `run` returns.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore/OpenAIClient.swift Core/Sources/BMWCodingCore/ClaudeClient.swift Core/Tests/BMWCodingCoreTests/OpenAIClientTests.swift Core/Tests/BMWCodingCoreTests/OpenAIAPITests.swift
git commit -m "OpenAI: Responses client with retries, the tool loop and the no-web resend"
```

---

### Task 4: The provider seam: ModelClient, the prompt per provider, owner messages, Transcript items

**Files:**
- Create: `Core/Sources/BMWCodingCore/ModelClient.swift`
- Modify: `Core/Sources/BMWCodingCore/ClaudeClient.swift` (conformance), `Core/Sources/BMWCodingCore/OpenAIClient.swift` (conformance), `Core/Sources/BMWCodingCore/Mechanic.swift`, `Core/Sources/BMWCodingCore/Conversation.swift` (`Transcript`), `Core/Tests/BMWCodingCoreTests/MechanicTests.swift`, `Core/Tests/BMWCodingCoreTests/ConversationTests.swift`, `Core/Tests/BMWCodingCoreTests/FakeTransport.swift` (`FakeHTTPTransport`)

**Interfaces:**
- Produces:

```swift
/// A client the mechanic runs a turn on: the conversation's messages in the provider's own wire shape.
public protocol ModelClient: AnyObject {
    func run(
        messages: inout [JSON], system: [JSON], tools: [JSON], model: String, effort: String,
        runTool: (ToolCall) async throws -> ToolResult, onUpdate: (StreamUpdate) -> Void, onUsage: (Usage) -> Void
    ) async throws -> Turn
}

/// One plain HTTP exchange, for the sign-in endpoints and the model list.
public struct HTTPReply: Equatable, Sendable { public var status: Int; public var headers: [String: String]; public var body: Data }
public protocol HTTPTransport: AnyObject { func send(_ request: URLRequest) async throws -> HTTPReply }
public final class URLSessionHTTPTransport: HTTPTransport { public init() }
```

  - `ClaudeClient: ModelClient` and `OpenAIClient: ModelClient` (their `run` already has the signature; `ClaudeClient.run`'s default for `onUsage` stays).
  - `Mechanic.WebTools { case searchAndFetch, search }`; `Mechanic.systemPrompt(carContext: String, web: WebTools = .searchAndFetch) -> [JSON]`.
  - `Mechanic.ownerMessage(_ text: String, provider: Provider) -> JSON` and `Mechanic.isOwnerMessage(_ message: JSON, provider: Provider) -> Bool`.
  - `Transcript.Item`, `Transcript.Kind`, `Transcript.items(in messages: [JSON], provider: Provider) -> [Transcript.Item]`:

```swift
public enum Transcript {
    public struct Item: Equatable, Sendable {
        /// The index in the conversation's messages the item comes from.
        public var messageIndex: Int
        /// The index of the block or part inside that message, for stable row ids.
        public var place: Int
        public var kind: Kind
    }
    public enum Kind: Equatable, Sendable {
        case owner(String)
        /// One run of the mechanic's text.
        case mechanic(String)
        /// A tool the mechanic called, with its result when the conversation holds one.
        case toolCall(ToolCall, result: ToolResult?)
        case webSearch(query: String)
        case webFetch(url: String)
        case fallback
        /// The pages the message cites, after its last text.
        case sources([Sources.Source])
    }
    public static func items(in messages: [JSON], provider: Provider) -> [Item]
}
```

- [ ] **Step 1: Write the failing tests**

In `MechanicTests.swift`:

```swift
@Test func thePromptNamesTheWebToolsTheProviderHas() {
    let both = Mechanic.systemPrompt(carContext: "{}")[0]["text"]?.string ?? ""
    let searchOnly = Mechanic.systemPrompt(carContext: "{}", web: .search)[0]["text"]?.string ?? ""
    #expect(both.contains("- web_search and web_fetch: use them to look up"))
    #expect(searchOnly.contains("- web_search: use it to look up") && !searchOnly.contains("web_fetch"))
    #expect(Mechanic.systemPrompt(carContext: "ctx", web: .search)[1]["text"]?.string == "The car, from the health check:\nctx")
}

@Test func ownerMessagesTakeTheProvidersShape() {
    let claude = Mechanic.ownerMessage("hi", provider: .anthropic)
    #expect(claude == .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("hi")])])]))
    let gpt = Mechanic.ownerMessage("hi", provider: .openai)
    #expect(gpt == .object(["type": .string("message"), "role": .string("user"), "content": .array([.object(["type": .string("input_text"), "text": .string("hi")])])]))
    #expect(Mechanic.isOwnerMessage(claude, provider: .anthropic) && Mechanic.isOwnerMessage(gpt, provider: .openai))
    let result = JSON.object(["type": .string("function_call_output"), "call_id": .string("c"), "output": .string("x")])
    #expect(!Mechanic.isOwnerMessage(result, provider: .openai))
    let toolResults = JSON.object(["role": .string("user"), "content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("t"), "content": .string("x")])])])
    #expect(!Mechanic.isOwnerMessage(toolResults, provider: .anthropic))
}
```

In `ConversationTests.swift`:

```swift
@Test func anthropicMessagesBecomeTranscriptItems() {
    let messages: [JSON] = [
        Mechanic.ownerMessage("Summarize", provider: .anthropic),
        .object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("server_tool_use"), "id": .string("s1"), "name": .string("web_search"), "input": .object(["query": .string("B1F3E")])]),
            .object(["type": .string("tool_use"), "id": .string("t1"), "name": .string("read_faults"), "input": .object(["module": .string("40")])]),
        ])]),
        .object(["role": .string("user"), "content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("t1"), "content": .string("none"), "is_error": .bool(false)])])]),
        .object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("text"), "text": .string("Based on ")]),
            .object(["type": .string("text"), "text": .string("the results"), "citations": .array([.object(["type": .string("web_search_result_location"), "url": .string("https://a.example/p"), "title": .string("Page")])])]),
        ])]),
    ]
    let items = Transcript.items(in: messages, provider: .anthropic)
    #expect(items.map(\.kind) == [
        .owner("Summarize"), .webSearch(query: "B1F3E"),
        .toolCall(ToolCall(id: "t1", name: "read_faults", input: .object(["module": .string("40")])), result: ToolResult("none")),
        .mechanic("Based on the results"), .sources([Sources.Source(url: "https://a.example/p", title: "Page")]),
    ])
    #expect(items.map(\.messageIndex) == [0, 1, 1, 3, 3] && items[3].place == 1)
}

@Test func openAIItemsBecomeTranscriptItems() throws {
    let call = try JSON.parse(Data(functionCallItem(0, callId: "call_1", name: "read_faults", arguments: #"{"module":"40"}"#).json.utf8))
    let answer = try JSON.parse(Data(textItem(0, "Nothing stored.", citations: [("https://a.example/p", "Page"), ("https://a.example/p", "Page again")]).json.utf8))
    let messages: [JSON] = [
        Mechanic.ownerMessage("Summarize", provider: .openai),
        try JSON.parse(Data(reasoningItem(0).json.utf8)),
        try JSON.parse(Data(webSearchItem(0, query: "B1F3E").json.utf8)),
        .object(["id": .string("ws_2"), "type": .string("web_search_call"), "status": .string("completed"), "action": .object(["type": .string("open_page"), "url": .string("https://a.example/p")])]),
        call,
        .object(["type": .string("function_call_output"), "call_id": .string("call_1"), "namespace": .string("car"), "name": .string("read_faults"), "output": .string("Error: module 40 did not answer")]),
        answer,
    ]
    let items = Transcript.items(in: messages, provider: .openai)
    #expect(items.map(\.kind) == [
        .owner("Summarize"), .webSearch(query: "B1F3E"), .webFetch(url: "https://a.example/p"),
        .toolCall(ToolCall(id: "call_1", name: "read_faults", input: .object(["module": .string("40")])), result: ToolResult("module 40 did not answer", isError: true)),
        .mechanic("Nothing stored."), .sources([Sources.Source(url: "https://a.example/p", title: "Page")]),
    ])
    #expect(items.map(\.messageIndex) == [0, 2, 3, 4, 6, 6])
}
```

`FakeTransport.swift` gains, for Task 5:

```swift
/// Answers `send` from a script, one reply per request, in order, and records every request.
final class FakeHTTPTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var script: [HTTPReply]
    init(_ script: [HTTPReply]) { self.script = script }
    func send(_ request: URLRequest) async throws -> HTTPReply {
        requests.append(request)
        precondition(!script.isEmpty, "unscripted request")
        return script.removeFirst()
    }
}
func reply(_ status: Int, _ body: String, headers: [String: String] = [:]) -> HTTPReply {
    HTTPReply(status: status, headers: headers, body: Data(body.utf8))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter 'MechanicTests|ConversationTests'`
Expected: compile errors `extra argument 'web' in call`, `cannot find 'Transcript.Item'`, `type 'Mechanic' has no member 'ownerMessage'`.

- [ ] **Step 3: Implement**

`ModelClient.swift`: the protocol, `HTTPReply`, `HTTPTransport`, `URLSessionHTTPTransport` (`URLSession.shared.data(for:)`, lower-cased header names, a `URLError` thrown as it is). Add the conformances in the two client files.

`Mechanic.swift`: `instructions` becomes a function of `WebTools`, the only line that changes being the web line: `- web_search and web_fetch: use them to look up what a code means, known faults and service notes for this car.` for `.searchAndFetch`, `- web_search: use it to look up what a code means, known faults and service notes for this car.` for `.search`. `ownerMessage` and `isOwnerMessage` as the tests pin (`isOwnerMessage` for `.openai`: `type` is `message` or absent, `role` is `user`, and `content` is a string or holds an `input_text` part).

`Conversation.swift`, `Transcript.items`: for `.anthropic`, the rules `ChatView.rows` applies today, moved here: an owner message (by `isOwnerMessage`) gives `.owner` per text block; an assistant message gives, per block in order, `.mechanic` for each text run at the run's last block, `.toolCall` for a `tool_use` with the `tool_result` of the same id from the following message (nil when none), `.webSearch`/`.webFetch` for a `server_tool_use` by its name, `.fallback` for a `fallback` block, and after its last text block `.sources(Sources.list(in: content))` when that list is not empty. For `.openai`, per item in order: a user `message` gives `.owner` with its `input_text` texts joined (`place` 0); an assistant `message` gives `.mechanic` with its `output_text` texts joined (`place` 0) and then `.sources` from the `url_citation` annotations of its parts, unique by URL with the first title, when any (`place` 1); a `function_call` gives `.toolCall` with `ToolCall(id: call_id, name:, input: parsed arguments or {})` and the result from the first later `function_call_output` with that `call_id`, its `output` read as `ToolResult(text, isError: false)` or, when it starts with `Error: `, `ToolResult(rest, isError: true)`; a `web_search_call` gives `.webSearch(query: action.query)` for an action of type `search` and `.webFetch(url: action.url)` for `open_page`; `function_call_output`, `reasoning` and anything else give nothing.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/BMWCodingCore Core/Tests/BMWCodingCoreTests
git commit -m "Core: ModelClient seam, the prompt per provider and Transcript items for both shapes"
```

---

### Task 5: Sign in with ChatGPT: the OAuth flow, the ID token, the session and the loopback listener

**Files:**
- Create: `Core/Sources/BMWCodingCore/ChatGPTSignIn.swift`, `Core/Sources/BMWCodingCore/LoopbackListener.swift`, `Core/Tests/BMWCodingCoreTests/ChatGPTSignInTests.swift`, `Core/Tests/BMWCodingCoreTests/LoopbackListenerTests.swift`

**Interfaces:**
- Consumes: `HTTPTransport`, `HTTPReply`, `JSON`, `Log`.
- Produces (all in `ChatGPTSignIn.swift` unless said):

```swift
public enum ChatGPT {
    public static let issuer = "https://auth.openai.com"
    public static let authorizationEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let revocationEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    public static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    public static let resource = "https://api.openai.com/v1"
    public static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let planScope = "chatgpt.tokens.use.direct"
    public static let agentName = "Vynscope"
    public static let registrationClientID = "dynamic_agent_client"
    public static let callbackPath = "/auth/callback"
}

/// What one sign-in attempt is keyed on; `random()` draws 32 bytes for each from the system generator.
public struct SignInAttempt: Equatable, Sendable {
    public var verifier: String, state: String, nonce: String
    public init(verifier: String, state: String, nonce: String)
    public static func random() -> SignInAttempt
    /// Base64url of SHA-256 of the verifier, unpadded (RFC 7636).
    public var challenge: String
}

/// The sign-in as kept between launches.
public struct ChatGPTAccount: Codable, Equatable, Sendable {
    public var email: String, issuer: String, subject: String, clientID: String, hostID: String
    public var idToken: String?, accessToken: String, refreshToken: String
    public var tokenType: String, expiresIn: Int, scopes: [String], savedAt: Date
    public var expiresAt: Date { savedAt.addingTimeInterval(TimeInterval(expiresIn)) }
    public var mayUsePlan: Bool { scopes.contains(ChatGPT.planScope) }
}

public enum SignInError: Error, Equatable {
    case denied                              // error=access_denied
    case stateMismatch
    case missingCode
    case registrationIncomplete              // first sign-in, no issued client_id in the callback
    case clientMismatch                      // a different client_id than the attempt's
    case tokenEndpoint(status: Int, error: String, description: String?)
    case invalidIDToken(String)              // which check failed
    case planNotGranted                      // chatgpt.tokens.use.direct missing
    case signedOut                           // the refresh failed terminally; sign in again
    case network(String)
}

public struct Callback: Equatable, Sendable { public var code: String, state: String, clientID: String? }

public struct TokenResponse: Equatable, Sendable {
    public var accessToken: String, refreshToken: String?, idToken: String?, tokenType: String, expiresIn: Int, scopes: [String]
    /// `SignInError.tokenEndpoint(status:error:description:)` when the body is an `error` object.
    public static func parse(_ data: Data, status: Int = 200) throws -> TokenResponse
}

public struct IDToken: Equatable, Sendable {
    public var issuer: String, audience: [String], subject: String, email: String?, nonce: String?, expires: Date
}

public enum ChatGPTSignIn {
    public static func authorizationURL(hostID: String, clientID: String?, attempt: SignInAttempt, redirect: URL, idTokenHint: String?, loginHint: String?) -> URL
    public static func parseCallback(_ url: URL, expectedState: String, expectedClientID: String?) throws -> Callback
    public static func exchangeRequest(code: String, attempt: SignInAttempt, clientID: String, redirect: URL) -> URLRequest
    public static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest
    public static func revokeRequest(refreshToken: String, clientID: String) -> URLRequest
    /// Decodes and checks the token: RS256 signature against the key of `jwks` with the token's `kid`, issuer, audience, expiry, nonce.
    public static func validate(idToken: String, jwks: JSON, clientID: String, nonce: String, now: Date) throws -> IDToken
    /// The terminal refresh errors: the tokens are unusable and a new sign-in is needed.
    public static let terminalRefreshErrors: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
}

/// Where the account and the per-device ids are kept (the app: the Keychain; tests: memory).
public protocol ChatGPTAccountStore: AnyObject {
    var account: ChatGPTAccount? { get set }
    /// The device's host id and the client id issued to it, kept across sign-outs.
    var hostID: String? { get set }
    var clientID: String? { get set }
}

public enum SignOutResult: Equatable, Sendable { case revoked, unconfirmed }

/// The sign-in's lifecycle on one device: begin, complete, a valid token for a request, sign out.
public final class ChatGPTSession {
    public init(store: any ChatGPTAccountStore, transport: any HTTPTransport, log: Log, now: @escaping () -> Date = { .now }, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
    public var account: ChatGPTAccount? { get }
    /// The host id, made on first use and kept.
    public func hostID() -> String
    /// The URL to open and the attempt to keep for `complete`.
    public func begin(redirect: URL) -> (url: URL, attempt: SignInAttempt)
    /// The callback URL the listener caught: exchanges the code, checks the ID token, keeps the account.
    public func complete(callback: URL, attempt: SignInAttempt, redirect: URL) async throws -> ChatGPTAccount
    /// The access token for a request, refreshed first when it expires within 60 s; `SignInError.signedOut` when the refresh fails terminally (the account is then dropped, the registration kept).
    public func validAccessToken() async throws -> String
    public func signOut() async -> SignOutResult
    /// Drops the account without revoking it (the API said the token is no longer valid); the registration stays.
    public func forget()
}
```

  In `LoopbackListener.swift`:

```swift
/// Listens on 127.0.0.1 for the browser's redirect to /auth/callback.
public final class LoopbackListener {
    public init()
    /// Starts listening on an ephemeral port; the redirect URL `http://127.0.0.1:<port>/auth/callback`.
    public func start() throws -> URL
    /// The first request to the callback path, as a URL with its query; answers it with a page saying the owner can close it. Throws `CancellationError` when cancelled.
    public func callback() async throws -> URL
    public func stop()
}
```

- [ ] **Step 1: Write the failing tests** in `ChatGPTSignInTests.swift`

```swift
import Foundation
import Testing
@testable import BMWCodingCore

let redirect = URL(string: "http://127.0.0.1:1455/auth/callback")!
let attempt = SignInAttempt(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "st4te", nonce: "n0nce")

@Test func thePKCEChallengeFollowsRFC7636() {
    #expect(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let random = SignInAttempt.random()
    #expect(random.verifier.count >= 43 && random.state != random.nonce)
}

@Test func theFirstSignInRegistersAndALaterOneReusesTheClient() throws {
    let first = ChatGPTSignIn.authorizationURL(hostID: "urn:uuid:1234", clientID: nil, attempt: attempt, redirect: redirect, idTokenHint: nil, loginHint: nil)
    let query = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
    #expect(first.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
    #expect(query["client_id"] == "dynamic_agent_client" && query["agent_name_hint"] == "Vynscope")
    #expect(query["ext_agent_host_id"] == "urn:uuid:1234" && query["response_type"] == "code")
    #expect(query["redirect_uri"] == "http://127.0.0.1:1455/auth/callback" && query["resource"] == "https://api.openai.com/v1")
    #expect(query["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
    #expect(query["state"] == "st4te" && query["nonce"] == "n0nce")
    #expect(query["code_challenge"] == attempt.challenge && query["code_challenge_method"] == "S256")
    let later = ChatGPTSignIn.authorizationURL(hostID: "urn:uuid:1234", clientID: "oaiapp_abc", attempt: attempt, redirect: redirect, idTokenHint: "eyJ.id.token", loginHint: "scott@example.com")
    let laterQuery = try #require(URLComponents(url: later, resolvingAgainstBaseURL: false)?.queryItems).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
    #expect(laterQuery["client_id"] == "oaiapp_abc" && laterQuery["agent_name_hint"] == nil)
    #expect(laterQuery["id_token_hint"] == "eyJ.id.token" && laterQuery["login_hint"] == "scott@example.com")
}

@Test func theCallbackIsCheckedBeforeAnythingIsExchanged() throws {
    let good = URL(string: "http://127.0.0.1:1455/auth/callback?code=c0de&state=st4te&scope=openid&client_id=oaiapp_abc")!
    #expect(try ChatGPTSignIn.parseCallback(good, expectedState: "st4te", expectedClientID: nil) == Callback(code: "c0de", state: "st4te", clientID: "oaiapp_abc"))
    #expect(throws: SignInError.stateMismatch) { try ChatGPTSignIn.parseCallback(good, expectedState: "other", expectedClientID: nil) }
    #expect(throws: SignInError.denied) { try ChatGPTSignIn.parseCallback(URL(string: "http://127.0.0.1:1455/auth/callback?error=access_denied&state=st4te")!, expectedState: "st4te", expectedClientID: nil) }
    #expect(throws: SignInError.registrationIncomplete) { try ChatGPTSignIn.parseCallback(URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=st4te")!, expectedState: "st4te", expectedClientID: nil) }
    #expect(throws: SignInError.clientMismatch) { try ChatGPTSignIn.parseCallback(good, expectedState: "st4te", expectedClientID: "oaiapp_other") }
    #expect(try ChatGPTSignIn.parseCallback(URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=st4te")!, expectedState: "st4te", expectedClientID: "oaiapp_abc").clientID == nil)
}

@Test func theTokenRequestsAreFormEncodedWithoutASecret() throws {
    let exchange = ChatGPTSignIn.exchangeRequest(code: "c0de", attempt: attempt, clientID: "oaiapp_abc", redirect: redirect)
    #expect(exchange.url == ChatGPT.tokenEndpoint && exchange.httpMethod == "POST")
    #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let form = String(decoding: try #require(exchange.httpBody), as: UTF8.self)
    #expect(form.contains("grant_type=authorization_code") && form.contains("code=c0de") && form.contains("client_id=oaiapp_abc"))
    #expect(form.contains("code_verifier=\(attempt.verifier)") && form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback"))
    #expect(form.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1") && !form.contains("client_secret"))
    let refresh = String(decoding: try #require(ChatGPTSignIn.refreshRequest(refreshToken: "rt", clientID: "oaiapp_abc").httpBody), as: UTF8.self)
    #expect(refresh.contains("grant_type=refresh_token") && refresh.contains("refresh_token=rt") && !refresh.contains("scope="))
    let revoke = ChatGPTSignIn.revokeRequest(refreshToken: "rt", clientID: "oaiapp_abc")
    #expect(revoke.url == ChatGPT.revocationEndpoint)
    #expect(String(decoding: try #require(revoke.httpBody), as: UTF8.self) == "token=rt&token_type_hint=refresh_token&client_id=oaiapp_abc")
}

@Test func aTokenResponseParsesAndAnErrorOneThrows() throws {
    let data = Data(#"{"access_token":"at","refresh_token":"rt","id_token":"it","token_type":"Bearer","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"}"#.utf8)
    let response = try TokenResponse.parse(data)
    #expect(response.accessToken == "at" && response.refreshToken == "rt" && response.expiresIn == 3600)
    #expect(response.scopes.contains("chatgpt.tokens.use.direct"))
    #expect(throws: SignInError.tokenEndpoint(status: 400, error: "invalid_grant", description: "expired")) {
        try TokenResponse.parse(Data(#"{"error":"invalid_grant","error_description":"expired"}"#.utf8), status: 400)
    }
}

@Test func theIDTokenIsCheckedAgainstTheJWKSAndTheAttempt() throws {
    // `signedIDToken.jwt` and `signedIDToken.jwks` are a token signed by a throwaway 2048-bit RSA key made with
    // `openssl` when this test was written, with iss https://auth.openai.com, aud oaiapp_abc, nonce n0nce, email
    // scott@example.com, exp 2030-01-01T00:00:00Z; the JWK holds that key's n and e under kid "k1".
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: signedIDToken.jwks, clientID: "oaiapp_abc", nonce: "n0nce", now: now)
    #expect(token.issuer == "https://auth.openai.com" && token.audience == ["oaiapp_abc"] && token.email == "scott@example.com")
    #expect(throws: SignInError.invalidIDToken("nonce")) { try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: signedIDToken.jwks, clientID: "oaiapp_abc", nonce: "other", now: now) }
    #expect(throws: SignInError.invalidIDToken("audience")) { try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: signedIDToken.jwks, clientID: "oaiapp_zzz", nonce: "n0nce", now: now) }
    #expect(throws: SignInError.invalidIDToken("expired")) { try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: signedIDToken.jwks, clientID: "oaiapp_abc", nonce: "n0nce", now: Date(timeIntervalSince1970: 2_000_000_000)) }
    #expect(throws: SignInError.invalidIDToken("signature")) { try ChatGPTSignIn.validate(idToken: signedIDToken.tampered, jwks: signedIDToken.jwks, clientID: "oaiapp_abc", nonce: "n0nce", now: now) }
    #expect(throws: SignInError.invalidIDToken("key")) { try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: .object(["keys": .array([])]), clientID: "oaiapp_abc", nonce: "n0nce", now: now) }
}

final class MemoryAccountStore: ChatGPTAccountStore {
    var account: ChatGPTAccount?
    var hostID: String?
    var clientID: String?
}

/// A session over a scripted transport, its clock at `now`.
func session(_ store: MemoryAccountStore, _ transport: FakeHTTPTransport, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> ChatGPTSession {
    ChatGPTSession(store: store, transport: transport, log: Log(), now: { now }, sleep: { _ in })
}
let tokenJSON = #"{"access_token":"at1","refresh_token":"rt1","id_token":"\#(signedIDToken.jwt)","token_type":"Bearer","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"}"#

@Test func aFirstSignInRegistersExchangesChecksAndKeepsTheAccount() async throws {
    let store = MemoryAccountStore()
    let transport = FakeHTTPTransport([reply(200, tokenJSON), reply(200, String(decoding: signedIDToken.jwks.encoded(), as: UTF8.self))])
    let session = session(store, transport)
    let (url, attempt) = session.begin(redirect: redirect)
    #expect(url.absoluteString.contains("client_id=dynamic_agent_client") && store.hostID?.hasPrefix("urn:uuid:") == true)
    // The test's attempt replaces the random one so that the signed token's nonce matches.
    let fixed = SignInAttempt(verifier: attempt.verifier, state: attempt.state, nonce: "n0nce")
    let callback = URL(string: "http://127.0.0.1:1455/auth/callback?code=c0de&state=\(attempt.state)&client_id=oaiapp_abc")!
    let account = try await session.complete(callback: callback, attempt: fixed, redirect: redirect)
    #expect(account.email == "scott@example.com" && account.clientID == "oaiapp_abc" && account.mayUsePlan)
    #expect(store.account == account && store.clientID == "oaiapp_abc")
    #expect(transport.requests[0].url == ChatGPT.tokenEndpoint && transport.requests[1].url == ChatGPT.jwksURL)
}

@Test func aSignInWithoutThePlanGrantIsRefused() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"
    let noPlan = tokenJSON.replacingOccurrences(of: " chatgpt.tokens.use.direct", with: "")
    let transport = FakeHTTPTransport([reply(200, noPlan), reply(200, String(decoding: signedIDToken.jwks.encoded(), as: UTF8.self))])
    let session = session(store, transport)
    let (url, attempt) = session.begin(redirect: redirect)
    #expect(url.absoluteString.contains("client_id=oaiapp_abc"))
    let fixed = SignInAttempt(verifier: attempt.verifier, state: attempt.state, nonce: "n0nce")
    await #expect(throws: SignInError.planNotGranted) {
        try await session.complete(callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(attempt.state)")!, attempt: fixed, redirect: redirect)
    }
    #expect(store.account == nil && store.clientID == "oaiapp_abc")
}

@Test func anExpiringTokenIsRefreshedAndATerminalFailureSignsOut() async throws {
    let store = MemoryAccountStore()
    let saved = Date(timeIntervalSince1970: 1_800_000_000)
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"
    store.account = ChatGPTAccount(email: "scott@example.com", issuer: ChatGPT.issuer, subject: "sub", clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: nil, accessToken: "at1", refreshToken: "rt1", tokenType: "Bearer", expiresIn: 3600, scopes: [ChatGPT.planScope], savedAt: saved)
    let fresh = session(store, FakeHTTPTransport([]), now: saved.addingTimeInterval(1000))
    #expect(try await fresh.validAccessToken() == "at1")
    let rotated = #"{"access_token":"at2","refresh_token":"rt2","token_type":"Bearer","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"}"#
    let transport = FakeHTTPTransport([reply(200, rotated)])
    let expiring = session(store, transport, now: saved.addingTimeInterval(3560))
    #expect(try await expiring.validAccessToken() == "at2")
    #expect(store.account?.refreshToken == "rt2" && store.account?.savedAt == saved.addingTimeInterval(3560))
    #expect(String(decoding: try #require(transport.requests[0].httpBody), as: UTF8.self).contains("refresh_token=rt1"))
    let failing = session(store, FakeHTTPTransport([reply(400, #"{"error":"refresh_token_expired"}"#)]), now: saved.addingTimeInterval(10_000))
    await #expect(throws: SignInError.signedOut) { try await failing.validAccessToken() }
    #expect(store.account == nil && store.clientID == "oaiapp_abc" && store.hostID == "urn:uuid:1")
    store.account = ChatGPTAccount(email: "scott@example.com", issuer: ChatGPT.issuer, subject: "sub", clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: nil, accessToken: "at1", refreshToken: "rt1", tokenType: "Bearer", expiresIn: 3600, scopes: [ChatGPT.planScope], savedAt: saved)
    let flaky = session(store, FakeHTTPTransport([reply(503, "")]), now: saved.addingTimeInterval(10_000))
    await #expect(throws: SignInError.network("refresh failed with status 503")) { try await flaky.validAccessToken() }
    #expect(store.account != nil)
}

@Test func signOutRevokesClearsTheTokensAndKeepsTheRegistration() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"
    store.account = ChatGPTAccount(email: "e", issuer: ChatGPT.issuer, subject: "s", clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: "it", accessToken: "at", refreshToken: "rt", tokenType: "Bearer", expiresIn: 3600, scopes: [], savedAt: .now)
    let transport = FakeHTTPTransport([reply(503, ""), reply(200, "")])
    #expect(await session(store, transport).signOut() == .revoked)
    #expect(transport.requests.count == 2 && store.account == nil && store.clientID == "oaiapp_abc" && store.hostID == "urn:uuid:1")
    store.account = ChatGPTAccount(email: "e", issuer: ChatGPT.issuer, subject: "s", clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: nil, accessToken: "at", refreshToken: "rt", tokenType: "Bearer", expiresIn: 3600, scopes: [], savedAt: .now)
    #expect(await session(store, FakeHTTPTransport([reply(503, ""), reply(503, ""), reply(503, "")])).signOut() == .unconfirmed)
    #expect(store.account == nil)
}
```

`signedIDToken` is a test fixture enum in the same file with `static let jwt: String`, `static let tampered: String` (the same token with one character of its signature changed) and `static let jwks: JSON`. Make it when writing the test: `openssl genrsa -out /tmp/k.pem 2048`, build the header `{"alg":"RS256","kid":"k1","typ":"JWT"}` and the claims `{"iss":"https://auth.openai.com","aud":"oaiapp_abc","sub":"user_1","email":"scott@example.com","nonce":"n0nce","iat":1700000000,"exp":1893456000}`, base64url them, sign `<header>.<claims>` with `openssl dgst -sha256 -sign /tmp/k.pem | basenc --base64url -w0 | tr -d =`, and read `n` and `e` with `openssl rsa -in /tmp/k.pem -pubout -text -noout` (strip the colons, base64url the bytes). The private key is not kept. Paste the three strings; the key is a throwaway and the test never needs it again.

`LoopbackListenerTests.swift`:

```swift
import Foundation
import Testing
@testable import BMWCodingCore

@Test func theListenerCatchesTheRedirectAndAnswersWithAPage() async throws {
    let listener = LoopbackListener()
    let redirect = try listener.start()
    #expect(redirect.host == "127.0.0.1" && redirect.path == "/auth/callback" && (redirect.port ?? 0) > 0)
    async let caught = listener.callback()
    let hit = URL(string: redirect.absoluteString + "?code=c0de&state=s")!
    let (data, response) = try await URLSession.shared.data(from: hit)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("You can close this page"))
    let url = try await caught
    #expect(url.query == "code=c0de&state=s")
    listener.stop()
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter 'ChatGPTSignInTests|LoopbackListenerTests'`
Expected: compile errors `cannot find 'ChatGPTSignIn' in scope`, `cannot find 'LoopbackListener' in scope`.

- [ ] **Step 3: Implement `ChatGPTSignIn.swift`**

- `SignInAttempt.random()`: three 32-byte values from `SystemRandomNumberGenerator`, base64url without padding; `challenge` is `SHA256` (CryptoKit) of the verifier's UTF-8, base64url without padding.
- `authorizationURL`: `ChatGPT.authorizationEndpoint` with the query items in this order: `client_id`, `agent_name_hint` (first sign-in only), `ext_agent_host_id`, `response_type`, `redirect_uri`, `scope`, `resource`, `state`, `nonce`, `code_challenge_method`, `code_challenge`, then `id_token_hint` and `login_hint` when given. Build with `URLComponents` so the values are percent-encoded.
- `parseCallback`: `error=access_denied` → `.denied` (before the state check); `state` missing or different → `.stateMismatch`; no `code` → `.missingCode`; `expectedClientID == nil` and no `client_id` → `.registrationIncomplete`; `expectedClientID` set and `client_id` present and different → `.clientMismatch` (absent is fine and keeps the expected one).
- The three requests: `POST`, `Content-Type: application/x-www-form-urlencoded`, body built with `URLComponents.percentEncodedQuery` from items in the order the tests read (`grant_type`, `client_id`, `code`, `code_verifier`, `redirect_uri`, `resource`; refresh: `grant_type`, `client_id`, `refresh_token`, `resource`; revoke: `token`, `token_type_hint`, `client_id`). Reserved characters (`:`, `/`) are percent-encoded in values.
- `TokenResponse.parse(_ data: Data, status: Int = 200)`: a body with `error` throws `.tokenEndpoint(status:error:description:)`; `scope` is split on spaces.
- `validate`: split the JWT into three base64url parts; the header's `alg` must be `RS256` (else `invalidIDToken("alg")`); the key with the header's `kid` in `jwks.keys` (`kty` `RSA`, `n`, `e`), else `invalidIDToken("key")`; the public key from `n` and `e` through `SecKeyCreateWithData` (PKCS#1 `RSAPublicKey` DER built from the two integers; `kSecAttrKeyTypeRSA`, `kSecAttrKeyClassPublic`) and `SecKeyVerifySignature(.rsaSignatureMessagePKCS1v15SHA256)` over the `<header>.<claims>` bytes, else `invalidIDToken("signature")`; then `iss == ChatGPT.issuer` (`"issuer"`), `aud` (a string or an array) contains `clientID` (`"audience"`), `exp > now` (`"expired"`), `nonce == nonce` (`"nonce"`). Claims decoded with `JSON.parse`.
- `ChatGPTSession`: `hostID()` returns the store's or makes `urn:uuid:<UUID().uuidString.lowercased()>` and keeps it. `begin` makes a random attempt and the URL with the store's `clientID` and the account's `idToken`/`email` as hints. `complete`: `parseCallback` with the attempt's state and the store's client id; the client id to use is the callback's or the store's; `exchangeRequest` through the transport (a non-2xx or an `error` body → `TokenResponse.parse`'s error; a transport throw → `.network(description)`); the JWKS from `ChatGPT.jwksURL` (a `GET`, cached in the session for the session's life); `validate` with the attempt's nonce; `planScope` must be among the granted scopes or `.planNotGranted` (nothing stored); then the account is built (`email` from the token or `""`, `savedAt: now()`), stored, and the client id kept in the store. `validAccessToken`: the account's token when `expiresAt > now() + 60`; otherwise `refreshRequest` through the transport: 2xx → the response's tokens replace the account's (a missing `refresh_token` keeps the old one), `savedAt: now()`, stored, returned; a 4xx whose `error` is in `terminalRefreshErrors` → the account is removed from the store (client id and host id stay) and `.signedOut`; anything else → `.network("refresh failed with status <status>")`, nothing changed. Refreshes are serialised through one in-flight task. `signOut`: with a refresh token, `revokeRequest` up to three tries on a 5xx or a transport throw, 1 s apart through `sleep`; a 2xx is `.revoked`; then the account is removed either way; `.unconfirmed` when no try answered 2xx. Log `ai: chatgpt sign-in <email>`, `ai: chatgpt token refreshed`, `ai: chatgpt signed out (revoked|unconfirmed)`; never a token, never the authorization URL.

- [ ] **Step 4: Implement `LoopbackListener.swift`**

`NWListener` with `NWParameters.tcp` whose `requiredLocalEndpoint` is `.hostPort(host: "127.0.0.1", port: .any)`; `start()` starts it on a private queue and waits for `.ready` to read the port (a semaphore or a continuation; `start` may be `async throws` if that is simpler, in which case the test awaits it). `callback()` awaits the first connection, reads until `\r\n\r\n`, parses the request line's target; a target whose path is `ChatGPT.callbackPath` is answered with `HTTP/1.1 200 OK`, `Content-Type: text/html; charset=utf-8`, `Connection: close` and a body `<html><body><p>Signed in. You can close this page and return to Vynscope.</p></body></html>` and resolved as `http://127.0.0.1:<port><target>`; any other target gets `404` and the listener keeps waiting. `stop()` cancels the listener and any connection. Cancellation of the awaiting task stops the listener and throws `CancellationError`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: all pass. The listener test takes under a second.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/BMWCodingCore/ChatGPTSignIn.swift Core/Sources/BMWCodingCore/LoopbackListener.swift Core/Tests/BMWCodingCoreTests/ChatGPTSignInTests.swift Core/Tests/BMWCodingCoreTests/LoopbackListenerTests.swift
git commit -m "Sign in with ChatGPT: the OAuth flow, ID-token checks, the session and the loopback listener"
```

---

### Task 6: The app: the sign-in record, the browser hand-off, the settings sheet

**Files:**
- Create: `App/ChatGPTBrowser.swift`
- Modify: `App/Keychain.swift`, `App/AIFlow.swift`, `App/AISettingsView.swift`, `App/AIStep.swift`

**Interfaces:**
- Consumes: `ChatGPTSession`, `ChatGPTAccountStore`, `ChatGPTAccount`, `SignInAttempt`, `SignInError`, `SignOutResult`, `LoopbackListener`, `URLSessionHTTPTransport`, `Provider`, `AISettings.provider` / `openAIModel`.
- Produces (app only, no tests: the builds and Task 8 check them):
  - `Keychain` keeps three generic-password items under service `com.smidley.vynscope`: account `anthropic-api-key` (as today), `chatgpt-account` (the `ChatGPTAccount` as JSON) and `chatgpt-registration` (JSON `{"hostID": …, "clientID": …}`); `static func data(for account: String) -> Data?`, `static func set(_ data: Data, for account: String) throws`, `static func delete(_ account: String) throws`, with `apiKey()`/`setAPIKey`/`deleteAPIKey` as thin wrappers.
  - `final class KeychainAccountStore: ChatGPTAccountStore` (MainActor) over those two items.
  - `enum ChatGPTBrowser`: on macOS `static func open(_ url: URL)` through `NSWorkspace.shared.open`; on iOS `struct SafariSheet: UIViewControllerRepresentable` wrapping `SFSafariViewController` for the URL, with `onDismiss` reported through the SwiftUI sheet's dismissal.
  - `AIFlow` gains: `private(set) var chatGPT: ChatGPTAccount?`, `private(set) var signingIn = false`, `var signInURL: URL?` (iOS: the sheet shows it while set), `private(set) var openAIModels: [(id: String, name: String)] = []`, `var showWelcome = false`, `var hasCredentials: Bool` (`.anthropic`: `hasKey`; `.openai`: `chatGPT?.mayUsePlan == true`), `func signInToChatGPT() async`, `func cancelSignIn()`, `func signOutOfChatGPT() async`, `func loadOpenAIModels() async`, and `private let session: ChatGPTSession` built in `init` over `KeychainAccountStore()`, `URLSessionHTTPTransport()` and `flow.log`.

- [ ] **Step 1: Keychain and the account store**

Generalise `Keychain` as above (the same `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, update-then-add). `KeychainAccountStore` encodes and decodes with `JSONEncoder`/`JSONDecoder` using `.iso8601` dates; a record that cannot be decoded reads as `nil`.

- [ ] **Step 2: The sign-in in `AIFlow`**

`signInToChatGPT()`: `guard !signingIn`; `signingIn = true`, `error = nil`; a `LoopbackListener` is started (an error → `error = "Could not start the sign-in: <description>"`); `session.begin(redirect:)`; the URL is opened (`ChatGPTBrowser.open` on macOS, `signInURL = url` on iOS) and the authorization URL is never logged; the callback is awaited in a `Task` kept in `signInTask` so `cancelSignIn()` (Cancel in the sheet, or the sheet dismissed) cancels it and stops the listener; `session.complete(callback:attempt:redirect:)`; on success `chatGPT = account`, `error = nil`, `await loadOpenAIModels()`, and when `UserDefaults.standard.bool(forKey: "chatgptWelcomeShown")` is false, `showWelcome = true` and the flag is set; the listener is stopped and `signInURL = nil`, `signingIn = false` on every exit. Errors to `error`: `.denied` → `Sign-in was cancelled in the browser`; `.planNotGranted` → `chatGPT` stays nil and `error = "Signed in, but Vynscope may not use your ChatGPT plan. Disconnect Vynscope in ChatGPT Settings, then sign in again and allow plan usage."`; `.stateMismatch`, `.clientMismatch`, `.registrationIncomplete`, `.missingCode` → `The sign-in did not complete; try again`; `.tokenEndpoint(_, let code, let description)` → `Sign-in failed (<code>): <description or code>`; `.invalidIDToken(let check)` → `The sign-in could not be verified (<check>)`; `.network(let text)` → `No connection to OpenAI: <text>`; `CancellationError` → nothing.

`signOutOfChatGPT()`: `let result = await session.signOut()`; `chatGPT = nil`, `openAIModels = []`; `.unconfirmed` → `error = "Signed out here, but OpenAI did not confirm it. You can disconnect Vynscope in ChatGPT Settings."`, else `error = nil`.

`loadOpenAIModels()`: `GET https://api.openai.com/v1/models` with `Authorization: Bearer <session.validAccessToken()>` through `URLSessionHTTPTransport`; the reply's `data` array filtered to entries whose `visibility` is `list` (or every entry when none has the key), as `(id: slug ?? id, name: display_name ?? id)` in the server's order; `settings.openAIModel` set to the first id when it is nil or no longer listed; a failure leaves the list as it was and sets `error = "Could not load the model list: <text>"`; `SignInError.signedOut` sets `chatGPT = nil` and `error = "Sign in to ChatGPT again in Settings"`.

`init` also reads `chatGPT` from the store so a relaunch shows the sign-in.

- [ ] **Step 3: The settings sheet**

Rewrite `AISettingsView`'s form as the design's shape A:
- `Section("AI provider")`: `Picker("Provider", selection: $ai.settings.provider)` over `Provider.allCases` by `displayName`, segmented.
- When `.anthropic`: the API key section exactly as today.
- When `.openai`, `Section("ChatGPT")`: with no account, `Button("Continue with ChatGPT") { Task { await ai.signInToChatGPT() } }` styled black with white text and OpenAI's white ChatGPT logo (an image set `ChatGPTLogo` added to `App/Assets.xcassets`, created if the app has no catalog, from the logo file OpenAI's branding page offers), disabled while `ai.signingIn`, with a `Cancel` button beside it while signing in; with an account, `Text("Signed in as \(email)")` and `Button("Sign out", role: .destructive)`; the `errorLine` under either.
- `Section("Model")`: for `.anthropic` the picker as today; for `.openai` a picker over `ai.openAIModels` bound to `$ai.settings.openAIModel` (disabled with the text `Sign in to see your models` when there is no account; the list is fetched with `.task` when the sheet opens signed in and the list is empty).
- The Effort section for both providers (the same three values; OpenAI sends them as `reasoning.effort`).
- The price table section only for `.anthropic`.
- `Section("Privacy")` with the sentence ending `to Anthropic under your own API key.` or `to OpenAI on your ChatGPT plan.` by provider.
- Conversations: as today.
- `.onChange(of: ai.settings.provider) { Task { await ai.switchProvider() } }` (`switchProvider` arrives in Task 7; here it is a stub that only saves the settings).
- The welcome: `.sheet(isPresented: $ai.showWelcome)` with the title `You're using your ChatGPT plan`, the body `Eligible AI requests in Vynscope use your ChatGPT plan. You can manage usage in ChatGPT settings.`, a `Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)` and a `Got it` button that dismisses.
- iOS: `.sheet(item: $ai.signInURL) { SafariSheet(url: $0) }` with `onDismiss { ai.cancelSignIn() }` (a sign-in that completed has already cleared `signInURL`, so the dismissal then cancels nothing). `URL` needs `Identifiable` for `sheet(item:)`: a one-line extension in `ChatGPTBrowser.swift`, `id` the `absoluteString`.

- [ ] **Step 4: The step's notice**

`AIStep`: the first branch is `if !ai.hasCredentials`, with the text `Enter your Anthropic API key in Settings to switch on the AI mechanic.` for `.anthropic` and `Sign in to ChatGPT in Settings to switch on the AI mechanic.` for `.openai`. The toolbar's New conversation button is disabled on `!ai.hasCredentials` instead of `!ai.hasKey`; `enter()` runs the health check on `hasCredentials`.

- [ ] **Step 5: Build both destinations**

Run: `make project && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet build`
Expected: both exit 0, no warnings in `App/`.

- [ ] **Step 6: Commit**

```bash
git add App
git commit -m "App: provider picker, Sign in with ChatGPT and the sign-in record"
```

---

### Task 7: The app: turns on either provider, the chat's ChatGPT states

**Files:**
- Modify: `App/AIFlow.swift`, `App/ChatView.swift`, `App/AIStep.swift`

**Interfaces:**
- Consumes: `ModelClient`, `ClaudeClient`, `OpenAIClient`, `OpenAIError`, `SignInError`, `Transcript.items`, `Mechanic.ownerMessage`/`isOwnerMessage`/`systemPrompt(carContext:web:)`, `Conversation.provider`, `TurnRecord.provider`/`webSearchDropped`, `ConversationStore.load(vin:provider:)`/`delete(vin:provider:)`.
- Produces: `AIFlow.switchProvider() async`, `AIFlow.planLimited: Bool`, `AIFlow.webSearchUnavailable: Set<String>`.

- [ ] **Step 1: Conversations per provider in `AIFlow`**

`enter()`, `newConversation()`, `checkAndSummarize()` and `runTurn` use `settings.provider`: `store.load(vin:provider:)`, `store.delete(vin:provider:)`, `Conversation(…, provider:)`, `Mechanic.ownerMessage(Mechanic.firstQuestion, provider:)`, and `TurnRecord(…, provider:)`. `switchProvider()`: nothing while `flow.busy`; otherwise `conversation = store.load(vin:provider:)` for the connected car, `phase = conversation == nil ? .idle : .ready`, `planLimited = false`, `error = nil`, and when there is no conversation and `hasCredentials`, the health check runs. `canRetry` and the retry effort use `Mechanic.isOwnerMessage(_:provider:)`. The model of a turn is `settings.model` for Anthropic and `settings.openAIModel` for OpenAI; a nil OpenAI model gives `error = "Pick a model in Settings"` and no turn.

- [ ] **Step 2: The client per provider in `runTurn`**

```swift
let client: any ModelClient
switch settings.provider {
case .anthropic:
    guard let key = Keychain.apiKey() else { error = "No API key: enter one in Settings"; return }
    client = ClaudeClient(transport: URLSessionTransport(), apiKey: key, log: flow.log)
case .openai:
    let token: String
    do { token = try await session.validAccessToken() } catch { ...SignInError.signedOut → chatGPT = nil, error = "Sign in to ChatGPT again in Settings"; other → error = "No connection to OpenAI: …"; return }
    let openAI = OpenAIClient(transport: URLSessionTransport(url: URL(string: "https://api.openai.com/v1/responses")!), accessToken: token, log: flow.log, webSearchUnavailable: webSearchUnavailable)
    client = openAI
}
```

The system prompt is `Mechanic.systemPrompt(carContext:, web: settings.provider == .anthropic ? .searchAndFetch : .search)`. After the turn, for OpenAI, `webSearchUnavailable = openAI.webSearchUnavailable` (also on a throw). The `onUpdate` `.block` handling covers both shapes: `AIFlow.serverToolLine(_:)` returns the line for an Anthropic `server_tool_use` as today and for an OpenAI `web_search_call` (`Searched the web: "<action.query>"` for `search`, `Fetched <action.url>` for `open_page`); a `function_call` or `reasoning` item gives no line and, like any non-text block, sets `textBroken`. The record of an answered turn gets `webSearchDropped: turn.webSearchDropped`.

- [ ] **Step 3: Errors and the plan states**

The `catch` maps, besides the `ClaudeError` cases: `OpenAIError.planLimit(code: "subscription_sharing_usage_limit_exceeded", _, _)` → `planLimited = true`, the record's `error = "Usage limit reached"` and, as on Stop, the text streamed so far kept as an assistant message item (`{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": …, "annotations": []}]}`; a private `assistantTextMessage(_:provider:)` builds the item or the Anthropic block); `.planLimit(code: "subscription_sharing_usage_unavailable", _, _)` → `error = "ChatGPT couldn't check your plan's usage; try again in a moment"`; `.unauthorized` → `error = "Sign in to ChatGPT again in Settings"`, `session.forget()` and `chatGPT = nil`; `.api(_, let code, let message, _)` → `API error (<code>): <message>`; `.badToolInput` → `The model sent an unreadable tool request; ask again`; `.network(let text)` → `No connection to OpenAI: <text>`; `SignInError.signedOut` → as `.unauthorized`. `send` and `retry` clear `planLimited`. The usage the plan-limit error carries goes into the turn's usage before the record is written.

- [ ] **Step 4: The chat over `Transcript.items`**

`ChatHistory.rows` builds from `Transcript.items(in: conversation.messages, provider: conversation.provider)`: `.owner` → an owner bubble except for `messageIndex == 0`; `.mechanic` → a mechanic bubble, with `Chips.split` applied to the last `.mechanic` item of the conversation when its message is the last assistant message; `.toolCall` → the activity line (`Not run: tool limit reached` when the result's content is `ClaudeClient.roundCapResult`, `…` when there is no result, else `Mechanic.activityLine`); `.webSearch` → `Searched the web: "<query>"`; `.webFetch` → `Fetched <url>` with the link; `.fallback` → `Answered by a fallback model`; `.sources` → the list. Row ids are `"\(messageIndex).\(place)"` with the suffixes used today. The turn rows under each owner message stay as they are, keyed by `record.messageIndex`, plus the no-web line `Web search isn't available on <record.model> with your plan; answering from the car's data only` as an orange caption under the question when `record.webSearchDropped`.

`UsageLine`: for a record whose `provider` is `.openai`, `counts` is `<in> in · <out> out · <reasoning> reasoning · on your ChatGPT plan` plus the searches, no dollars and no cached count; `ChatTotal` sums the Anthropic records' cost: `Total $0.0149 · 3 turns` when any Anthropic turn exists, `Total on your ChatGPT plan · 3 turns` when every turn ran on the plan.

`ChatView`: above the input bar, when `ai.settings.provider == .openai && ai.chatGPT != nil`, a caption row `Using ChatGPT plan · ` followed by `Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)` in `.caption`. When `ai.planLimited`, in place of the plain Try again: `Text("Usage limit reached. Review your plan or this app's limit in ChatGPT settings.")`, then an `HStack` with `Link("Manage usage", …)` styled `.borderedProminent` first and `Button("Try again") { ai.retry() }` second. The `errorLine` and the plain Try again stay for every other case.

- [ ] **Step 5: Build both destinations**

Run: `make project && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet build`
Expected: both exit 0, no warnings in `App/`.

- [ ] **Step 6: Commit**

```bash
git add App
git commit -m "App: turns on either provider, the ChatGPT plan states in the chat"
```

---

### Task 8: Verification (Scott)

**Files:**
- Modify: whatever the real sign-in and the real Responses API correct, most likely the namespace tool shape in `OpenAIClient.body(for:)`, the `error.param` the no-web resend keys on, the JWKS key lookup, and the matching tests; `docs/superpowers/specs/2026-10-28-ai-provider-login-design.md` ("Left to the builder" gets what OpenAI actually answered).

- [ ] **Step 1: At the desk, on the Mac**

Build with `make mac`. Settings: pick OpenAI, Continue with ChatGPT. The default browser opens OpenAI's sign-in; sign in and allow plan usage; the page says you can close it, the app shows the welcome once, then `Signed in as <your email>`; the model list fills. Quit and relaunch: still signed in, no welcome. Sign out: the row returns to the button; in ChatGPT Settings (chatgpt.com, connected apps) Vynscope's session is gone and the app is still listed. Disconnect Vynscope there, sign in again and decline plan usage: the row says `Signed in, but Vynscope may not use your ChatGPT plan` with the hint. Disconnect, sign in again allowing it. Check the Log: `ai: chatgpt sign-in <email>` and no `eyJ`, no `auth.openai.com/api/accounts/authorize`.

- [ ] **Step 2: At the desk, on the iPhone**

The same sign-in inside the Safari sheet; dismissing the sheet before signing in cancels cleanly; signing in dismisses it and shows the row.

- [ ] **Step 3: In the car, ignition on**

Provider OpenAI: the health check and summary run on the plan; the usage line ends `on your ChatGPT plan`, the caption `Using ChatGPT plan · Manage usage` sits above the input bar. Ask about a code: the answer cites numbered sources that open. Ask for a live value: the `Read identifier` line and the `0x22` read in the Log. Ask for a change: refused, nothing written. Pick each listed model once and ask a question; a model that cannot search shows the `Web search isn't available on <model>` line and the Log `ai: web search unavailable on <model>, asking again without it`; note the `error.param` the Log shows for the 400 (`ai: error 400 subscription_sharing_unsupported_capability: …`). In ChatGPT settings set Vynscope's weekly cap low, ask until `Usage limit reached` appears mid-turn: the text so far is kept, the usage line shows the turn, Manage usage opens the settings page, Try again works once the cap is raised. Switch to Anthropic: the Claude conversation of this car is as it was; switch back: the ChatGPT one is too. Stop during a round with several reads: no adapter command after Stop, the reads so far kept.

- [ ] **Step 4: Renewal**

Leave the app signed in for over an hour (or move the clock), ask again: the answer comes, the Log has `ai: chatgpt token refreshed`. Then, in ChatGPT Settings, disconnect Vynscope and ask: the chat says `Sign in to ChatGPT again in Settings` and the row shows the button.

- [ ] **Step 5: The Log and the files**

```bash
grep -cE 'eyJ|auth\.openai\.com/api/accounts/authorize|sk-ant-api' ~/Documents/Vynscope/log.txt
```

prints 0. `~/Documents/Vynscope/Conversations/` holds `<vin>-anthropic.json` and `<vin>-openai.json`, the old `<vin>.json` gone after the first save.

- [ ] **Step 6: Corrections**

Every correction becomes a code change with its test, `swift test` green, both builds green, and a commit `Sign-in corrections: <what changed>` or `OpenAI corrections: <what changed>`. Record in the design doc's "Left to the builder" what OpenAI answered: the accepted tools shape, the `error.param` of a refused web search, the model ids listed, the signing key id format.

---

## Spec coverage

| Spec section | Task |
|---|---|
| Intent, recon (Anthropic forbids, OpenAI allows) | Global Constraints |
| Goals: picker with the sign-in row following the provider | 6 |
| Goals: Anthropic unchanged, OpenAI on the plan with no key | 3, 6, 7 |
| Goals: the mechanic behaves the same where allowed | 3, 4, 7 |
| Goals: sign-in on Mac and iPhone | 5, 6 |
| Goals: renewal and Sign out | 5, 6, 7 |
| Goals: honest usage, plan exhaustion said | 2, 3, 7 |
| Non-goals (no Claude login, no OpenAI key, one account, no conversion) | Global Constraints, 1 |
| Anti-goals (no pooling, Keychain only, no silent fallback, no writes) | 5, 6, 7 |
| Constraints: SIWC endpoints, PKCE, registration, redirect, exchange, ID token, tokens, refresh | 5 |
| Constraints: sign-out revocation, kept registration, unconfirmed | 5, 6 |
| Constraints: credential protection, nothing logged | 5, 6, 7, 8 |
| Constraints: Responses request shape, omitted fields, namespace tools, web search | 3 |
| Constraints: error codes and recovery | 2, 3, 5, 7 |
| Constraints: UI guidelines (button, caption, welcome, limit state) | 6, 7 |
| Constraints: platform (Mac browser, iPhone Safari sheet, no network in tests) | 5, 6 |
| Settings: provider picker, rows, models, effort, prices, privacy, welcome | 6 |
| The AI step and chat: conversation per provider, usage line, limit, no-web line, sources | 1, 4, 7 |
| What the mechanic can do: same tools, prompt variant | 3, 4 |
| Code shape: seam, two clients, Transcript, sign-in type, Provider | 1, 2, 3, 4, 5 |
| Stage 3 note | none (a note) |
| Left to the builder | 3, 5, 6, 8 |
| What Scott verifies | 8 |
