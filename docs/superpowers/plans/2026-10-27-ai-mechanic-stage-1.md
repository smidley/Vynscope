# AI Mechanic Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks that write SwiftUI views also load `swiftui-specialist` and `swiftui-whats-new-27` (the SDK on this Mac is 27.1).

**Goal:** A fifth step in Vynscope, `✦ AI`, where an AI mechanic reads the connected car through the app's own read-only tools, looks things up on the web with sources shown, and talks to the owner in a chat, for Scott's i4 with his own API key.

**Architecture:** Everything that talks to the Claude API or to the car lives in the `BMWCodingCore` package: a `JSON` value type, the Messages API wire shapes and SSE assembly, a `ClaudeClient` with the streamed request, retries and the tool loop, a `Mechanic` with the six read-only tools and the health check over `Diag`, `DTC` parsing, a standard-OBD addressing mode in `Diag`, and a `Conversation` store with the price table. All of it is tested against a scripted transport and the scripted adapter link, never the real API. The app adds the step, the chat, the settings sheet and the Keychain helper on top of `Flow`.

**Tech Stack:** Swift 6 language mode, Swift 6.4 toolchain, SwiftUI, URLSession, Security framework (Keychain), Swift Testing, xcodegen 2.45, no third-party packages.

**Spec:** `docs/superpowers/specs/2026-10-26-ai-mechanic-design.md`. It assumes `docs/superpowers/specs/2026-10-26-bmw-coding-app-design.md` and the phase 1 code on `main`. API shapes below were pinned on 2026-10-27 from the Claude API reference (Messages API, streaming, web search and web fetch tool docs).

## Global Constraints

- Deployment targets iOS 26.0 and macOS 26.0; SDK 27.1, so the `@State` macro rules apply: never give a `@State` property an initial value and also assign it in an `init`.
- Swift 6 language mode, complete strict concurrency, default actor isolation `MainActor` in the package and the app, as phase 1. No third-party packages.
- The wire allow-list of the coding app grows by exactly two reads and nothing else: UDS `0x19 0x02` (fault codes by status mask `0xFF`) on BMW modules, and standard OBD-II modes `01`, `03`, `07` and `09` on the functional address `7DF`. The list is now: adapter setup, `0x22`, `0x19`, `0x3E`, `0x10 0x03`, standard OBD. No write of any kind: no `0x14`, no `0x2E`, no `0x31`, no clearing, no resets. The mechanic has no tool that writes.
- The Claude API is reached only at `POST https://api.anthropic.com/v1/messages` with headers `content-type: application/json`, `x-api-key: <key>`, `anthropic-version: 2026-10-21`, `anthropic-beta: server-side-fallback-2026-07-01`, `accept: text/event-stream`. Every request streams (`"stream": true`), `max_tokens` is `16000`, `fallbacks` is `"default"`, depth is `output_config.effort` (`high` for the health-check summary turn, the settings' effort, default `medium`, for every later turn). No `thinking` parameter, no `temperature`, no assistant prefill, `tool_choice` omitted (auto) except `{"type": "none"}` at the round cap.
- The API key lives in the Keychain and appears in no log entry, no file and no error text. No test calls Anthropic: every test runs against `FakeTransport` and `FakeLink`.
- Every tool call, every API request and its usage, and every adapter command the mechanic causes go through `Log`.
- Each conversation sends the car's data to Anthropic; the settings say so in exactly this sentence: `Each conversation sends your car's data (VIN, module identifications, fault codes and any coding bytes the mechanic reads) to Anthropic under your own API key.`
- Each task ends with `swift test` green (package tasks) or a successful Mac build plus iOS simulator build (app tasks), then a commit. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Adapter commands and byte layouts that the spec leaves to the car (the standard-OBD switch, the `0x19` record layout, which mode `01` PIDs the i4 answers) are pinned here as the first guess; Task 11 is where the car corrects them.

## Review Focus

- A wrong or expired API key: the chat shows one line `API error (authentication_error): <the API's message>`, nothing is retried, and the key is in no log line. Test in Task 2.
- A module that refuses the fault read (negative `0x11` or `0x12`) or never answers it: the health check records the refusal and goes on to the next module; the `read_faults` tool returns `is_error` with the reason and no crash. Tests in Tasks 6 and 7.
- A tool input the model mistypes (`"0x40"`, `"BDC_BODY3"`, `"3002h"`, an address not on the car): the tool answers with `is_error` naming the problem and sends nothing to the car. Test in Task 6.
- Stop pressed, or the API failing, in the middle of a tool round: the conversation on disk never holds a `tool_use` without its `tool_result`, so the next message still sends. Test in Task 3.
- The adapter dropping during the health check: the error is shown on the step, no conversation is created, and the check can be run again. Test in Task 7.

---

## File structure

```
Core/Sources/BMWCodingCore/
  JSON.swift                 JSON value type: Codable, Equatable, sorted-key encoding, lookups
  ClaudeAPI.swift            Usage, AssistantMessage, ClaudeError, SSE event parsing, StreamAssembler
  ClaudeClient.swift         Transport, URLSessionTransport, ClaudeRequest body, ClaudeClient (send with retries, tool loop)
  DTC.swift                  0x19 0x02 record parsing, standard OBD code strings, supported-PID bitmaps
  Diag.swift      (modify)   Addressing mode, obd(_:), readFaults(_:)
  ELM.swift       (modify)   obdSequence, bmwSequence
  Mechanic.swift             tool definitions, validation, the six tools, activity lines, health check, system prompt
  Conversation.swift         Conversation, TurnRecord, ConversationStore, Chips, Sources
  Pricing.swift              PriceTable, cost estimate
Core/Tests/BMWCodingCoreTests/
  FakeTransport.swift        scripted Transport
  JSONTests.swift ClaudeAPITests.swift ClaudeClientTests.swift DTCTests.swift
  DiagTests.swift (extend) MechanicTests.swift ConversationTests.swift PricingTests.swift
App/
  Flow.swift      (modify)   Step.ai, canGoNext
  VynscopeApp.swift (modify) the AI step in the switch, its indicator label
  AIFlow.swift               @Observable state: health check, turns, Stop, conversations, settings
  AISettingsView.swift       key, model, effort, price table, privacy note, Clear conversations
  Keychain.swift             the API key in the Keychain
  AIStep.swift               the step: key missing / health check progress / chat
  ChatView.swift             bubbles, activity lines, sources, chips, usage line, input, Stop
```

---

### Task 1: JSON value type, SSE parsing and stream assembly

**Files:**
- Create: `Core/Sources/BMWCodingCore/JSON.swift`, `Core/Sources/BMWCodingCore/ClaudeAPI.swift`, `Core/Tests/BMWCodingCoreTests/JSONTests.swift`, `Core/Tests/BMWCodingCoreTests/ClaudeAPITests.swift`

**Interfaces:**
- Produces:
  - `public enum JSON: Equatable, Sendable, Codable { case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null }` with `public static func parse(_ data: Data) throws -> JSON`, `public func encoded(pretty: Bool = false) -> Data` (always sorted keys; a whole number encodes without a fraction, `12` not `12.0`), `public subscript(key: String) -> JSON?` (nil on a non-object), `public var string: String?`, `public var int: Int?`, `public var array: [JSON]?`, `public var object: [String: JSON]?`, `public var bool: Bool?`.
  - `public struct Usage: Codable, Equatable, Sendable { public var inputTokens, outputTokens, cacheCreationInputTokens, cacheReadInputTokens, webSearchRequests, webFetchRequests: Int }` with a public memberwise `init(inputTokens:outputTokens:cacheCreationInputTokens:cacheReadInputTokens:webSearchRequests:webFetchRequests:)` and `public init(_ json: JSON)` (keys `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `server_tool_use.web_search_requests`, `server_tool_use.web_fetch_requests`; a missing key is 0), `public static func + (a: Usage, b: Usage) -> Usage` (field-wise), `public static let zero`.
  - `public struct AssistantMessage: Equatable, Sendable { public var id: String; public var model: String; public var content: [JSON]; public var stopReason: String?; public var stopDetails: JSON?; public var usage: Usage }`
  - `public enum ClaudeError: Error, Equatable { case api(status: Int?, type: String, message: String); case badToolInput(String); case network(String) }`
  - `public struct SSEEvent: Equatable, Sendable { public var name: String; public var data: String }` and `public struct SSEParser { public init(); public mutating func feed(_ line: String) -> SSEEvent? }`: `event: x` sets the name, `data: y` lines are joined with `\n`, lines starting with `:` and `id:` are ignored, a blank line ends the event and returns it (nil until then; a blank line with nothing pending returns nil). A missing `event:` name is `"message"`.
  - `public enum StreamUpdate: Equatable, Sendable { case text(String); case block(JSON); case finished }`
  - `public struct StreamAssembler { public init(); public mutating func apply(_ event: SSEEvent) throws -> StreamUpdate?; public func message() -> AssistantMessage }`

- [ ] **Step 1: Write the failing JSON tests**

```swift
import Testing
@testable import BMWCodingCore

@Test func jsonRoundTripsAndSortsKeys() throws {
    let data = Data(#"{"b":[1,2.5,true,null],"a":{"z":"s","y":12}}"#.utf8)
    let json = try JSON.parse(data)
    #expect(json["a"]?["y"]?.int == 12)
    #expect(json["b"]?.array?.count == 4)
    #expect(String(decoding: json.encoded(), as: UTF8.self) == #"{"a":{"y":12,"z":"s"},"b":[1,2.5,true,null]}"#)
    #expect(try JSON.parse(json.encoded(pretty: true)) == json)
}
@Test func jsonLookupsAreNilOnTheWrongType() {
    #expect(JSON.string("x")["k"] == nil)
    #expect(JSON.number(1).string == nil)
    #expect(JSON.object(["k": .bool(true)])["k"]?.bool == true)
}
```

- [ ] **Step 2: Write the failing SSE and assembly tests**

Fixtures are the documented event shapes; each is an array of lines fed to `SSEParser`, its events to `StreamAssembler`.

```swift
func assemble(_ text: String) throws -> (AssistantMessage, [StreamUpdate]) {
    var parser = SSEParser(), assembler = StreamAssembler(), updates: [StreamUpdate] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let event = parser.feed(String(line)) else { continue }
        if let update = try assembler.apply(event) { updates.append(update) }
    }
    return (assembler.message(), updates)
}

@Test func sseParserJoinsDataAndIgnoresComments() {
    var p = SSEParser()
    #expect(p.feed(": keep-alive") == nil)
    #expect(p.feed("event: ping") == nil)
    #expect(p.feed("data: {\"a\":1") == nil)
    #expect(p.feed("data: }") == nil)
    #expect(p.feed("") == SSEEvent(name: "ping", data: "{\"a\":1\n}"))
    #expect(p.feed("") == nil)
}
@Test func assemblesTextToolUseThinkingAndUsage() throws {
    let stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":472,"cache_creation_input_tokens":10,"cache_read_input_tokens":400,"output_tokens":2}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig1"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: ping
    data: {"type":"ping"}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"read that."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: content_block_start
    data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_faults","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"module\\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" \\"40\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":2}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"input_tokens":472,"cache_creation_input_tokens":10,"cache_read_input_tokens":400,"output_tokens":89}}

    event: message_stop
    data: {"type":"message_stop"}

    """
    let (message, updates) = try assemble(stream)
    #expect(message.id == "msg_1" && message.model == "claude-opus-5-5" && message.stopReason == "tool_use")
    #expect(message.usage == Usage(inputTokens: 472, outputTokens: 89, cacheCreationInputTokens: 10,
                                   cacheReadInputTokens: 400, webSearchRequests: 0, webFetchRequests: 0))
    #expect(message.content[0] == .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig1")]))
    #expect(message.content[1] == .object(["type": .string("text"), "text": .string("Let me read that.")]))
    #expect(message.content[2]["input"] == .object(["module": .string("40")]))
    #expect(updates.contains(.text("Let me ")) && updates.contains(.text("read that.")))
    #expect(updates.last == .finished)
    #expect(updates.filter { if case .block = $0 { true } else { false } }.count == 3)
}
@Test func assemblesServerToolUseResultsAndCitations() throws {
    let stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":10,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":\\"B1F3E BMW G26\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","title":"Camera washer","url":"https://example.com/a","encrypted_content":"EqgfCio","page_age":null}]}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: content_block_start
    data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"The nozzle"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://example.com/a","title":"Camera washer","encrypted_index":"Eo8B","cited_text":"the washer nozzle"}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"future_delta","x":1}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":2}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":10682,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":510,"server_tool_use":{"web_search_requests":1}}}

    event: message_stop
    data: {"type":"message_stop"}

    """
    let (message, _) = try assemble(stream)
    #expect(message.content[0]["input"]?["query"]?.string == "B1F3E BMW G26")
    #expect(message.content[1]["content"]?.array?.first?["encrypted_content"]?.string == "EqgfCio")
    #expect(message.content[2]["citations"]?.array?.count == 1)
    #expect(message.content[2]["citations"]?.array?.first?["url"]?.string == "https://example.com/a")
    #expect(message.usage.webSearchRequests == 1 && message.usage.inputTokens == 10682)
}
@Test func errorEventThrowsAndBadToolInputThrows() throws {
    let error = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
    #expect(throws: ClaudeError.api(status: nil, type: "overloaded_error", message: "Overloaded")) { try assemble(error) }
    let bad = """
    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_value","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"module\\": "}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    """
    #expect(throws: ClaudeError.badToolInput("{\"module\": ")) { try assemble(bad) }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Core && swift test --filter "JSONTests|ClaudeAPITests"`
Expected: FAIL, `JSON` not found.

- [ ] **Step 4: Implement `JSON`**

`Codable` through single-value containers; `encoded` uses `JSONEncoder` with `.sortedKeys` (plus `.prettyPrinted` when asked) and no `withoutEscapingSlashes` change. A `number` whose value is whole and below 2^53 encodes as an integer.

- [ ] **Step 5: Implement `Usage`, `AssistantMessage`, `ClaudeError`, `SSEParser`, `StreamAssembler`**

Assembly rules: `message_start` takes `id`, `model` and `usage` from `message`; `content_block_start` stores a copy of `content_block` at `index` and opens an empty partial-JSON buffer for a `tool_use` or `server_tool_use`; `content_block_delta` applies `text_delta` to `text`, `input_json_delta` to the buffer, `thinking_delta` to `thinking`, `signature_delta` to `signature`, `citations_delta` by appending `citation` to the block's `citations` array (created when missing), and ignores any other delta type; `content_block_stop` parses a non-empty buffer as a JSON object into `input` (an empty buffer gives `{}`, unparsable text throws `badToolInput(text)`) and returns `.block(block)`; `message_delta` takes `delta.stop_reason`, `delta.stop_details` and replaces every usage field the event carries (they are cumulative); `message_stop` returns `.finished`; `ping` and unknown event names return nil; `error` throws `api(status: nil, type: error.type, message: error.message)`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: PASS, all tests (111 from phase 1 plus these).

- [ ] **Step 7: Commit**

```bash
git add Core
git commit -m "JSON value type, SSE parsing and Messages stream assembly"
```

---

### Task 2: ClaudeClient: transport, request body, retries, errors

**Files:**
- Create: `Core/Sources/BMWCodingCore/ClaudeClient.swift`, `Core/Tests/BMWCodingCoreTests/FakeTransport.swift`, `Core/Tests/BMWCodingCoreTests/ClaudeClientTests.swift`

**Interfaces:**
- Consumes: Task 1's `JSON`, `SSEParser`, `StreamAssembler`, `AssistantMessage`, `Usage`, `ClaudeError`, `StreamUpdate`; phase 1's `Log`.
- Produces:
  - `public protocol Transport: AnyObject { func post(body: Data, headers: [String: String]) async throws -> TransportResponse }` and `public struct TransportResponse { public var status: Int; public var headers: [String: String]; public var lines: AsyncThrowingStream<String, any Error> }` (header names lower-cased).
  - `public final class URLSessionTransport: Transport` posting to `https://api.anthropic.com/v1/messages` with `URLSession.shared.bytes(for:)`, the response's `.lines` wrapped into the stream; a `URLError` becomes `ClaudeError.network(error.localizedDescription)`.
  - `public struct ClaudeRequest: Equatable, Sendable { public var model: String; public var effort: String; public var system: [JSON]; public var tools: [JSON]; public var messages: [JSON]; public var toolChoiceNone: Bool = false }`
  - `public final class ClaudeClient { public init(transport: any Transport, apiKey: String, log: Log, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }); public static func body(for request: ClaudeRequest) -> JSON; public func send(_ request: ClaudeRequest, onUpdate: (StreamUpdate) -> Void) async throws -> AssistantMessage }`
  - The body: `model`, `max_tokens` 16000, `stream` true, `fallbacks` `"default"`, `output_config` `{"effort": effort}`, `system` (the request's blocks, the last one given `cache_control: {"type": "ephemeral"}`), `tools` (as given), `messages` (as given, the last content block of the last message given `cache_control: {"type": "ephemeral"}` when that message's content is an array), and `tool_choice: {"type": "none"}` only when `toolChoiceNone`. Headers exactly as in Global Constraints.
  - Retries: a status of 429, 500 or 529, or an `error` event that arrives before any content block started, is retried after 1 s, then 2 s (three tries in all); a `429` with an integer `retry-after` header sleeps that many seconds instead (at most 30). Any other non-2xx status throws `ClaudeError.api(status:type:message:)` from the body's `{"type":"error","error":{"type","message"}}` (an unparsable body gives type `http_<status>` and the body's first 200 characters). An `error` event after a content block started is thrown, not retried.
  - Logging: `ai: request <model> effort <effort>, <n> messages, <t> tools` before each try, `ai: retry <k> after <status or error type>` on a retry, and `ai: <stop_reason> · in <input_tokens> · cached <cache_read_input_tokens> · out <output_tokens> · searches <n>` on success. The key is in no log line.

- [ ] **Step 1: Write `FakeTransport`**

```swift
@testable import BMWCodingCore

/// Answers `post` from a script, one entry per call, in order, and records every call.
final class FakeTransport: Transport {
    struct Call { var body: JSON; var headers: [String: String] }
    private(set) var calls: [Call] = []
    private var script: [(status: Int, headers: [String: String], text: String)]

    init(_ script: [(status: Int, headers: [String: String], text: String)]) { self.script = script }

    func post(body: Data, headers: [String: String]) async throws -> TransportResponse {
        calls.append(Call(body: try JSON.parse(body), headers: headers))
        precondition(!script.isEmpty, "unscripted request")
        let next = script.removeFirst()
        let lines = next.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return TransportResponse(status: next.status, headers: next.headers, lines: AsyncThrowingStream { c in
            for line in lines { c.yield(line) }
            c.finish()
        })
    }
}

/// A minimal end_turn stream with `text` and the given usage.
func textStream(_ text: String, input: Int = 100, cached: Int = 0, output: Int = 10) -> String { /* message_start, one text block, message_delta with stop_reason end_turn and cumulative usage, message_stop */ }
```

- [ ] **Step 2: Write the failing tests**

```swift
@Test func bodyAndHeadersFollowTheSpec() async throws {
    let transport = FakeTransport([(200, [:], textStream("hi"))])
    let client = ClaudeClient(transport: transport, apiKey: "sk-ant-secret", log: Log())
    let request = ClaudeRequest(model: "claude-opus-5-5", effort: "high",
        system: [.object(["type": .string("text"), "text": .string("rules")]), .object(["type": .string("text"), "text": .string("car")])],
        tools: [.object(["name": .string("get_vehicle"), "strict": .bool(true)])],
        messages: [.object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("hello")])])])])
    _ = try await client.send(request) { _ in }
    let call = try #require(transport.calls.first)
    #expect(call.headers["x-api-key"] == "sk-ant-secret")
    #expect(call.headers["anthropic-version"] == "2026-10-21")
    #expect(call.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
    #expect(call.headers["content-type"] == "application/json")
    #expect(call.body["max_tokens"]?.int == 16000 && call.body["stream"]?.bool == true)
    #expect(call.body["fallbacks"]?.string == "default")
    #expect(call.body["output_config"]?["effort"]?.string == "high")
    #expect(call.body["tool_choice"] == nil && call.body["thinking"] == nil && call.body["temperature"] == nil)
    #expect(call.body["system"]?.array?[0]["cache_control"] == nil)
    #expect(call.body["system"]?.array?[1]["cache_control"] == .object(["type": .string("ephemeral")]))
    #expect(call.body["messages"]?.array?[0]["content"]?.array?[0]["cache_control"] == .object(["type": .string("ephemeral")]))
}
@Test func streamsTextAndReportsUsage() async throws {
    let transport = FakeTransport([(200, [:], textStream("Hello owner", input: 300, cached: 250, output: 12))])
    var seen = ""
    let message = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).send(request()) {
        if case .text(let t) = $0 { seen += t }
    }
    #expect(seen == "Hello owner" && message.stopReason == "end_turn")
    #expect(message.usage.cacheReadInputTokens == 250 && message.usage.outputTokens == 12)
}
@Test func retriesRateLimitOverloadAndServerErrors() async throws {
    var slept: [Duration] = []
    let transport = FakeTransport([
        (429, ["retry-after": "5"], "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}"),
        (529, [:], "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"),
        (200, [:], textStream("ok"))])
    let client = ClaudeClient(transport: transport, apiKey: "k", log: Log()) { slept.append($0) }
    _ = try await client.send(request()) { _ in }
    #expect(slept == [.seconds(5), .seconds(2)])
    #expect(transport.calls.count == 3)
}
@Test func givesUpAfterThreeTries() async throws {
    let overloaded = (529, [String: String](), "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}")
    let transport = FakeTransport([overloaded, overloaded, overloaded])
    let client = ClaudeClient(transport: transport, apiKey: "k", log: Log()) { _ in }
    await #expect(throws: ClaudeError.api(status: 529, type: "overloaded_error", message: "Overloaded")) {
        try await client.send(request()) { _ in }
    }
    #expect(transport.calls.count == 3)
}
@Test func authErrorIsNotRetriedAndKeyIsNeverLogged() async throws {
    let transport = FakeTransport([(401, [:], "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}")])
    let log = Log()
    let client = ClaudeClient(transport: transport, apiKey: "sk-ant-secret", log: log)
    await #expect(throws: ClaudeError.api(status: 401, type: "authentication_error", message: "invalid x-api-key")) {
        try await client.send(request()) { _ in }
    }
    #expect(transport.calls.count == 1)
    #expect(!log.entries.contains { $0.text.contains("sk-ant-secret") })
}
@Test func errorEventBeforeContentIsRetriedAfterContentIsThrown() async throws {
    let early = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
    let late = textStream("partial").replacingOccurrences(of: "event: message_delta", with: early + "event: message_delta")
    let transport = FakeTransport([(200, [:], early), (200, [:], textStream("fine")), (200, [:], late)])
    let client = ClaudeClient(transport: transport, apiKey: "k", log: Log()) { _ in }
    #expect(try await client.send(request()) { _ in }.content.first?["text"]?.string == "fine")
    await #expect(throws: ClaudeError.api(status: nil, type: "overloaded_error", message: "Overloaded")) {
        try await client.send(request()) { _ in }
    }
}
```

`request()` is a one-line helper returning a minimal `ClaudeRequest` with one user text message.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Core && swift test --filter ClaudeClientTests`
Expected: FAIL, `ClaudeClient` not found.

- [ ] **Step 4: Implement `Transport`, `URLSessionTransport`, `ClaudeRequest`, `ClaudeClient.body(for:)` and `send`**

`send` builds the body once, then loops over at most three tries: post, and on a retryable status sleep and try again; on a 2xx run the lines through `SSEParser` and `StreamAssembler`, calling `onUpdate` for every update, and return `assembler.message()` after `.finished` (a stream that ends without `message_stop` is also returned as assembled). The partial-JSON and `citations_delta` handling is Task 1's; the client only forwards events.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Core
git commit -m "ClaudeClient: streamed Messages requests with retries and error mapping"
```

---

### Task 3: The tool loop

**Files:**
- Modify: `Core/Sources/BMWCodingCore/ClaudeClient.swift`
- Test: `Core/Tests/BMWCodingCoreTests/ClaudeClientTests.swift` (extend)

**Interfaces:**
- Consumes: Task 2's `ClaudeClient.send`, `ClaudeRequest`; Task 1's `JSON`, `Usage`, `StreamUpdate`.
- Produces:
  - `public struct ToolCall: Equatable, Sendable { public var id: String; public var name: String; public var input: JSON }`
  - `public struct ToolResult: Equatable, Sendable { public var content: String; public var isError: Bool; public init(_ content: String, isError: Bool = false) }`
  - `public struct Turn: Equatable, Sendable { public var usage: Usage; public var rounds: Int; public var refused: Bool; public var truncated: Bool; public var stoppedAtRoundCap: Bool }`
  - `public static let roundCap = 12` on `ClaudeClient`.
  - `public func run(messages: inout [JSON], system: [JSON], tools: [JSON], model: String, effort: String, runTool: (ToolCall) async throws -> ToolResult, onUpdate: (StreamUpdate) -> Void) async throws -> Turn` on `ClaudeClient`. `messages` already ends with the owner's message when called.
  - `public static func echo(_ content: [JSON]) -> [JSON]`: the assistant content as it is sent back. Without a `fallback` block it is the content unchanged. Otherwise, before the last `fallback` block only `text` blocks and `server_tool_use` blocks that a later `*_tool_result` block with the same `tool_use_id` pairs with, together with those result blocks, are kept; `thinking`, `redacted_thinking`, `tool_use`, unpaired `server_tool_use` and every other type before it are dropped; the `fallback` block and everything after it are kept.
  - The loop, exactly: with `rounds = 0`, send; append `{"role": "assistant", "content": echo(content)}` unless that content is empty; then on `tool_use`: `rounds += 1`; if `rounds > roundCap`, append one user message of `tool_result` blocks all `is_error` with content `Tool limit for this message reached; answer with what you already have`, send once more with `toolChoiceNone`, append its echoed content, set `stoppedAtRoundCap`, stop; else run every `tool_use` block of the content in order through `runTool` (its `input` object; a non-object input is a `ToolResult("tool input was not an object", isError: true)` without calling `runTool`), append one user message holding one `{"type": "tool_result", "tool_use_id": id, "content": result.content}` per call, with `"is_error": true` when it failed, and send again; on `pause_turn`: send again with the messages unchanged (counts as a round); on `refusal`: replace the appended assistant message with its `text` blocks only (drop it when there are none), set `refused`, stop, running no tool; on `max_tokens` with a `tool_use` in the content: the same text-only replacement, set `truncated`, stop; on `end_turn` or anything else: stop. `usage` is the sum over every request of the turn. When any request after the first of a conversation (one where `messages` already held an assistant message) reports `cacheReadInputTokens == 0`, log `ai: no cache read on this request`. If `send` or `runTool` throws (a `ClaudeError`, a `LinkError`, a `CancellationError`), `messages` is restored to its value at entry before the error is rethrown.

- [ ] **Step 1: Write the failing tests**

`toolUseStream(id:name:input:)` is a helper like `textStream` whose message ends with `stop_reason` `tool_use` and one `tool_use` block (with a `thinking` block before it); `pauseStream()` ends with `pause_turn`; `refusalStream(text:)` ends with `refusal` and holds one text and one `tool_use` block.

```swift
@Test func runsToolsAndEchoesContentVerbatim() async throws {
    let transport = FakeTransport([
        (200, [:], toolUseStream(id: "toolu_1", name: "read_faults", input: #"{"module":"40"}"#, output: 50)),
        (200, [:], textStream("Two faults.", input: 900, cached: 800, output: 20))])
    var messages: [JSON] = [userText("What is wrong?")]
    var calls: [ToolCall] = []
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "claude-opus-5-5", effort: "medium",
        runTool: { calls.append($0); return ToolResult(#"{"faults":[]}"#) }, onUpdate: { _ in })
    #expect(calls == [ToolCall(id: "toolu_1", name: "read_faults", input: .object(["module": .string("40")]))])
    #expect(messages.count == 4)
    #expect(messages[1]["content"]?.array?.contains { $0["type"]?.string == "thinking" } == true)
    #expect(messages[2] == .object(["role": .string("user"), "content": .array([.object([
        "type": .string("tool_result"), "tool_use_id": .string("toolu_1"), "content": .string(#"{"faults":[]}"#)])])]))
    #expect(transport.calls[1].body["messages"]?.array?.count == 3)
    #expect(turn.rounds == 1 && turn.usage.outputTokens == 70 && turn.usage.cacheReadInputTokens == 800)
}
@Test func toolFailureIsAnErrorResult() async throws {
    let transport = FakeTransport([(200, [:], toolUseStream(id: "t", name: "read_value", input: #"{"module":"40","did":"3000"}"#)), (200, [:], textStream("ok"))])
    var messages: [JSON] = [userText("q")]
    _ = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ToolResult("module 40 did not answer", isError: true) }, onUpdate: { _ in })
    #expect(messages[2]["content"]?.array?.first?["is_error"]?.bool == true)
}
@Test func stopsAtTheRoundCapWithToolChoiceNone() async throws {
    var script = (0..<13).map { _ in (200, [String: String](), toolUseStream(id: "t", name: "get_vehicle", input: "{}")) }
    script.append((200, [:], textStream("Here is what I have.")))
    let transport = FakeTransport(script)
    var messages: [JSON] = [userText("q")]
    var ran = 0
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ran += 1; return ToolResult("{}") }, onUpdate: { _ in })
    #expect(ran == 12 && turn.rounds == 13 && turn.stoppedAtRoundCap)
    let last = try #require(transport.calls.last)
    #expect(last.body["tool_choice"] == .object(["type": .string("none")]))
    #expect(messages[messages.count - 2]["content"]?.array?.first?["content"]?.string == "Tool limit for this message reached; answer with what you already have")
    #expect(messages.last?["content"]?.array?.first?["text"]?.string == "Here is what I have.")
}
@Test func refusalRunsNoToolAndKeepsOnlyText() async throws {
    let transport = FakeTransport([(200, [:], refusalStream(text: "I cannot"))])
    var messages: [JSON] = [userText("q")]
    var ran = false
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ran = true; return ToolResult("") }, onUpdate: { _ in })
    #expect(!ran && turn.refused)
    #expect(messages.count == 2 && messages[1]["content"]?.array?.count == 1)
    #expect(messages[1]["content"]?.array?.first?["type"]?.string == "text")
}
@Test func pauseTurnIsResentUnchanged() async throws {
    let transport = FakeTransport([(200, [:], pauseStream()), (200, [:], textStream("done"))])
    var messages: [JSON] = [userText("q")]
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ToolResult("") }, onUpdate: { _ in })
    #expect(transport.calls[1].body["messages"]?.array?.count == 2)
    #expect(transport.calls[1].body["messages"]?.array?.last?["role"]?.string == "assistant")
    #expect(turn.rounds == 1 && messages.count == 3)
}
@Test func truncatedToolInputRunsNothing() async throws {
    let stream = toolUseStream(id: "t", name: "get_vehicle", input: "{}").replacingOccurrences(of: "\"stop_reason\":\"tool_use\"", with: "\"stop_reason\":\"max_tokens\"")
    let transport = FakeTransport([(200, [:], stream)])
    var messages: [JSON] = [userText("q")]
    var ran = false
    let turn = try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
        messages: &messages, system: [], tools: [], model: "m", effort: "medium",
        runTool: { _ in ran = true; return ToolResult("") }, onUpdate: { _ in })
    #expect(!ran && turn.truncated && messages.count == 1)
}
@Test func aFailedTurnLeavesTheMessagesAsTheyWere() async throws {
    let transport = FakeTransport([(200, [:], toolUseStream(id: "t", name: "get_vehicle", input: "{}"))])
    var messages: [JSON] = [userText("q")]
    let before = messages
    struct Boom: Error {}
    await #expect(throws: Boom.self) {
        try await ClaudeClient(transport: transport, apiKey: "k", log: Log()).run(
            messages: &messages, system: [], tools: [], model: "m", effort: "medium",
            runTool: { _ in throw Boom() }, onUpdate: { _ in })
    }
    #expect(messages == before)
}
@Test func echoDropsModelInternalsBeforeAFallback() {
    let text: JSON = .object(["type": .string("text"), "text": .string("a")])
    let thinking: JSON = .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("s")])
    let toolUse: JSON = .object(["type": .string("tool_use"), "id": .string("t"), "name": .string("x"), "input": .object([:])])
    let search: JSON = .object(["type": .string("server_tool_use"), "id": .string("srv"), "name": .string("web_search"), "input": .object([:])])
    let result: JSON = .object(["type": .string("web_search_tool_result"), "tool_use_id": .string("srv"), "content": .array([])])
    let lone: JSON = .object(["type": .string("server_tool_use"), "id": .string("srv2"), "name": .string("web_search"), "input": .object([:])])
    let fallback: JSON = .object(["type": .string("fallback"), "from": .object(["model": .string("a")]), "to": .object(["model": .string("b")])])
    #expect(ClaudeClient.echo([thinking, text, toolUse]) == [thinking, text, toolUse])
    #expect(ClaudeClient.echo([thinking, text, toolUse, search, result, lone, fallback, thinking, text]) == [text, search, result, fallback, thinking, text])
}
```

`runTool` is `(ToolCall) async throws -> ToolResult` in the signature so the restore test can throw; a tool that fails normally returns `isError`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter ClaudeClientTests`
Expected: FAIL, `run` not found.

- [ ] **Step 3: Implement `ToolCall`, `ToolResult`, `Turn`, `echo` and `run`**

`run` copies `messages` at entry, works on the copy, and assigns it back only on a normal return. The `tool_use` blocks of a round are read from the assembled content, not from stream updates.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Core
git commit -m "ClaudeClient: the tool loop with round cap, refusal, pause_turn and fallback echo"
```

---

### Task 4: DTC records and standard OBD codes

**Files:**
- Create: `Core/Sources/BMWCodingCore/DTC.swift`, `Core/Tests/BMWCodingCoreTests/DTCTests.swift`

**Interfaces:**
- Produces:
  - `public struct DTC: Equatable, Hashable, Sendable { public let code: String; public let status: UInt8 }`
  - `public enum DTCParse { public static func bmwFaults(_ payload: [UInt8]) -> [DTC]?; public static func obdCodes(_ payload: [UInt8]) -> [String]?; public static func obdCode(_ a: UInt8, _ b: UInt8) -> String; public static func supportedPIDs(_ payload: [UInt8], base: UInt8) -> [UInt8]? }`
  - `bmwFaults`: the positive answer to `0x19 0x02`, first guess at the ISO 14229 layout to be confirmed in the car: `0x59`, `0x02`, one availability-mask byte, then 4-byte records `[high, middle, low, status]`; `code` is the three bytes as six upper-case hex digits; a trailing partial record is dropped; nil unless the payload starts `59 02` and has the mask byte.
  - `obdCodes`: the answer to mode `03` or `07` on CAN: `0x43` or `0x47`, a count byte, then 2-byte codes; every whole pair present is read (the count is not trusted) and `00 00` pairs are skipped; nil unless the first byte is `0x43` or `0x47`.
  - `obdCode`: bits 7-6 of `a` select `P`, `C`, `B`, `U` for `0`-`3`, bits 5-4 the first digit, then the low nibble of `a` and both nibbles of `b` as hex digits.
  - `supportedPIDs`: the answer to a mode `01` support PID (`41`, the PID asked for, four bytes of flags, bit 7 of the first byte being PID `base + 1`); returns the supported PIDs in order; nil unless the payload is `41 <base>` plus four bytes.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import BMWCodingCore

@Test func parsesBMWFaultRecords() {
    let payload: [UInt8] = [0x59, 0x02, 0xFF, 0x80, 0x1E, 0x2B, 0x2F, 0xB1, 0xF3, 0xE0, 0x08, 0x12]
    #expect(DTCParse.bmwFaults(payload) == [DTC(code: "801E2B", status: 0x2F), DTC(code: "B1F3E0", status: 0x08)])
    #expect(DTCParse.bmwFaults([0x59, 0x02, 0xFF]) == [])
    #expect(DTCParse.bmwFaults([0x59, 0x02]) == nil)
    #expect(DTCParse.bmwFaults([0x62, 0x30, 0x00]) == nil)
}
@Test func decodesStandardCodes() {
    #expect(DTCParse.obdCode(0x04, 0x20) == "P0420")
    #expect(DTCParse.obdCode(0x41, 0x23) == "C0123")
    #expect(DTCParse.obdCode(0x93, 0xA1) == "B13A1")
    #expect(DTCParse.obdCode(0xC1, 0x00) == "U0100")
    #expect(DTCParse.obdCodes([0x43, 0x02, 0x04, 0x20, 0xC1, 0x00, 0x00, 0x00]) == ["P0420", "U0100"])
    #expect(DTCParse.obdCodes([0x47, 0x00]) == [])
    #expect(DTCParse.obdCodes([0x41, 0x00]) == nil)
}
@Test func readsSupportedPIDs() {
    #expect(DTCParse.supportedPIDs([0x41, 0x00, 0x80, 0x00, 0x00, 0x01], base: 0x00) == [0x01, 0x20])
    #expect(DTCParse.supportedPIDs([0x41, 0x20, 0x00, 0x00, 0x00, 0x00], base: 0x20) == [])
    #expect(DTCParse.supportedPIDs([0x41, 0x00, 0x80], base: 0x00) == nil)
    #expect(DTCParse.supportedPIDs([0x41, 0x20, 0x80, 0x00, 0x00, 0x00], base: 0x00) == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter DTCTests`
Expected: FAIL, `DTCParse` not found.

- [ ] **Step 3: Implement `DTC.swift`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Core
git commit -m "DTC: fault records, standard OBD codes and supported-PID bitmaps"
```

---

### Task 5: Standard-OBD addressing in Diag and the fault read

**Files:**
- Modify: `Core/Sources/BMWCodingCore/Diag.swift`, `Core/Sources/BMWCodingCore/ELM.swift`
- Test: `Core/Tests/BMWCodingCoreTests/DiagTests.swift` (extend)

**Interfaces:**
- Consumes: phase 1's `Diag`, `ELM.initSequence`, `ISOTP.reassemble`, `ELM.parse`.
- Produces:
  - `public extension ELM { static let obdSequence = ["ATCAF1", "ATFCSM 0", "ATAR", "ATSH 7DF"]; static let bmwSequence = ["ATCAF0", "ATFCSM 1", "ATSH 6F1", "ATFCSH 6F1"] }` (first guess, confirmed in Task 11: auto-formatting on so the adapter builds the ISO-TP frames, reassembles and sends flow control itself, its automatic flow-control mode, every reply id accepted again, the functional request header; and back).
  - `public enum Addressing: Equatable, Sendable { case bmw, obd }` and `public private(set) var addressing: Addressing` on `Diag`, `.bmw` after `setUp()`.
  - `public func obd(_ payload: [UInt8]) async throws -> [UInt16: [UInt8]]` on `Diag`: switches to `.obd` with `obdSequence` when not there (every command must answer `OK`, as `setUp`), sends the payload as a hex line (`01 00`), and returns, by the CAN id each answered on (`0x7E8` to `0x7EF`), the complete payloads of the frames received: with auto-formatting on each line is `7E8 06 41 00 BE 3E B8 11`, so byte 0 of the frame data is the ISO-TP PCI, and the frames of one id are reassembled with `ISOTP.reassemble` after a `0x00` placeholder address byte is put in front of each; an id whose message is not `.complete`, or whose payload starts `0x7F`, is left out and logged as a note; `NO DATA` gives an empty dictionary; an adapter error line throws `LinkError.adapterError`. Uses `readTimeout`.
  - `public func readFaults(_ module: UInt8) async throws -> UDSResult`: `request(module, [0x19, 0x02, 0xFF])`; the caller selects the module first, as for `readDID`.
  - `select(module:)` first sends `bmwSequence` when `addressing == .obd` (each must answer `OK`), sets `.bmw` and clears `selected`, then proceeds as before, so the receive filter and flow-control address are set again. `setUp()` sets `.bmw`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func obdSwitchesOnceAndCollectsEveryECU() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "01 00": return ["7E8 06 41 00 BE 3E B8 11", "7E9 06 41 00 80 00 00 01"]
        case "03": return ["7E8 02 43 00"]
        default: return ["OK"] } }
    let diag = Diag(link: link, log: Log())
    let first = try await diag.obd([0x01, 0x00])
    #expect(first == [0x7E8: [0x41, 0x00, 0xBE, 0x3E, 0xB8, 0x11], 0x7E9: [0x41, 0x00, 0x80, 0x00, 0x00, 0x01]])
    #expect(try await diag.obd([0x03]) == [0x7E8: [0x43, 0x00]])
    #expect(link.sent == ["ATCAF1", "ATFCSM 0", "ATAR", "ATSH 7DF", "01 00", "03"])
    #expect(diag.addressing == .obd)
}
@Test func obdReassemblesMultiFrameAndSkipsNegatives() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "09 02": return ["7E8 10 14 49 02 01 57 42 59", "7E8 21 37 33 41 57 30 34 52", "7E8 22 46 46 41 4B 45 31 39", "7E9 03 7F 09 12"]
        default: return ["OK"] } }
    let answers = try await Diag(link: link, log: Log()).obd([0x09, 0x02])
    #expect(answers == [0x7E8: [0x49, 0x02, 0x01] + Array("WBY73AW04RFFAKE19".utf8)])
}
@Test func obdNoDataIsEmptyAndErrorsThrow() async throws {
    let silent = FakeLink { cmd in cmd == "07" ? ["NO DATA"] : ["OK"] }
    #expect(try await Diag(link: silent, log: Log()).obd([0x07]) == [:])
    let bus = FakeLink { cmd in cmd == "07" ? ["CAN ERROR"] : ["OK"] }
    await #expect(throws: LinkError.adapterError("CAN ERROR")) { try await Diag(link: bus, log: Log()).obd([0x07]) }
}
@Test func selectAfterObdRestoresBMWAddressing() async throws {
    let link = FakeLink { _ in ["OK"] }
    let diag = Diag(link: link, log: Log())
    try await diag.select(module: 0x40)
    _ = try await diag.obd([0x01, 0x00])
    try await diag.select(module: 0x40)
    #expect(link.sent.suffix(6) == ["ATCAF0", "ATFCSM 1", "ATSH 6F1", "ATFCSH 6F1", "ATCRA 640", "ATFCSD 40 30 00 00"])
    #expect(diag.addressing == .bmw)
}
@Test func readFaultsSendsNineteenTwo() async throws {
    let link = FakeLink { cmd in cmd == "40 03 19 02 FF 00 00 00" ? ["640 F1 07 59 02 FF 80 1E 2B 2F"] : ["OK"] }
    let diag = Diag(link: link, log: Log())
    try await diag.select(module: 0x40)
    #expect(try await diag.readFaults(0x40) == .positive([0x59, 0x02, 0xFF, 0x80, 0x1E, 0x2B, 0x2F]))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter DiagTests`
Expected: FAIL, `obd` not found.

- [ ] **Step 3: Implement the sequences, `Addressing`, `obd`, `readFaults` and the switch in `select`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: PASS, every phase 1 Diag test still green.

- [ ] **Step 5: Commit**

```bash
git add Core
git commit -m "Diag: standard OBD addressing mode and the 0x19 fault read"
```

---

### Task 6: Mechanic: the six read-only tools

**Files:**
- Create: `Core/Sources/BMWCodingCore/Mechanic.swift`, `Core/Tests/BMWCodingCoreTests/MechanicTests.swift`

**Interfaces:**
- Consumes: Task 3's `ToolCall`, `ToolResult`; Task 4's `DTCParse`; Task 5's `Diag.readFaults`, `Diag.obd`; phase 1's `Diag.select`, `Diag.readDID`, `DiscoveredModule`, `Backup`, `ModuleBackup`, `AdapterInfo`, `ISOTP.hexLine`, `Log`.
- Produces:
  - `public struct MechanicCar: Equatable, Sendable { public var vin: String; public var nickname: String; public var adapter: AdapterInfo; public var modules: [DiscoveredModule]; public var latestBackup: Backup?; public init(...) }`
  - `public final class Mechanic { public static let readValueCap = 40; public static let tools: [JSON]; public init(diag: Diag, car: MechanicCar, log: Log); public func beginMessage(); public func run(_ call: ToolCall) async throws -> ToolResult; public static func activityLine(for call: ToolCall, result: ToolResult, car: MechanicCar) -> String; public static func chassis(forVIN vin: String) -> String? }`
  - `tools`, in this order: `get_vehicle`, `read_faults`, `read_identification`, `read_coding`, `read_value`, `read_obd`, then `{"type": "web_search_20260209", "name": "web_search"}` and `{"type": "web_fetch_20260209", "name": "web_fetch"}`. Every client tool has `"strict": true`, an `input_schema` of `"type": "object"` with `"additionalProperties": false`, every property listed in `required`, and no `eager_input_streaming` (the inputs are a few characters; the server's default buffering validates them). Properties: `read_faults` `module` (string); `read_identification` `module`; `read_coding` `module` and `did` as `{"anyOf": [{"type": "string"}, {"type": "null"}]}`; `read_value` `module`, `did`; `read_obd` `pid`; `get_vehicle` none. Each property's description says its shape (`two hex digits of the diagnostic address, as "40"`; `four hex digits, as "3002"`; `two hex digits, as "42"`; `module` for `read_faults` adds `or "obd" for the standard OBD-II codes`).
  - Tool descriptions, verbatim:
    - `get_vehicle`: `The car as the app knows it: VIN, nickname, chassis, adapter, every module with its address, name, description, signed flag, hardware, software and coding files, and whether a backup exists. Call this when you need a module's address or want to know what is on the car.`
    - `read_faults`: `The fault codes stored in one module (UDS 0x19 0x02), or with module "obd" the standard OBD-II stored and pending codes from every controller that answers. The health check already holds every module's codes; call this again only to see whether they changed.`
    - `read_identification`: `What a module said about itself during the scan: its identification identifiers as hex and the parsed coding-file names. Reads nothing from the car. Call this to look at a module's hardware and software versions.`
    - `read_coding`: `A module's coding data. Without did: the identifiers in the latest backup and their sizes in bytes. With did: that identifier's bytes as hex from the latest backup, or a live read when the backup does not have it. The answer says which. Call this to look at how an option is coded.`
    - `read_value`: `A live read of one data identifier (UDS 0x22) on one module, bytes as hex, at most 40 per owner message. Call this for live values or for identifiers the backup does not have.`
    - `read_obd`: `One standard OBD-II mode 01 PID, the raw answer as hex per responding controller, for you to decode. Call this for live engine-side values; an electric car may answer nothing.`
  - Validation, before anything is sent: `module` must be exactly two hex digits (either case) naming an address in `car.modules`, except `"obd"` for `read_faults`; `did` exactly four hex digits; `pid` exactly two. A bad input is `ToolResult(isError: true)` with: `module must be the two-digit hex address of a listed module, as "40"`, `no module at address 5B on this car`, `"obd" is only valid for read_faults`, `did must be four hex digits, as "3002"`, `pid must be two hex digits, as "42"`, `missing <property>`, `unknown tool <name>`.
  - Results are JSON text (`JSON.encoded()`, sorted keys). Hex is upper case without spaces for bytes, two digits for addresses, four for identifiers.
    - `get_vehicle`: `{"adapter": {"firmware", "model"}, "backup": {"date": "<ISO 8601 UTC>", "modules": <count>} or null, "chassis": "G26 i4" or null, "modules": [{"address": "40", "codingFiles": [...], "description", "hardware", "name", "signed", "software"}], "nickname", "vin"}` (`null` for what a module did not give). `chassis(forVIN:)` is `"G26 i4"` for a VIN starting `WBY73`, else nil.
    - `read_faults`: select, `readFaults`, `DTCParse.bmwFaults` → `{"faults": [{"code": "801E2B", "status": "2F"}], "module": "40", "name": "BDC_BODY3"}`; a negative answer is the error `module 40 refused the fault read (0x11)`, silence `module 40 did not answer the fault read`, an unparsable positive `module 40 answered <hex> which is not a fault list`. With `"obd"`: `obd([0x03])` then `obd([0x07])`, decoded with `DTCParse.obdCodes` → `{"pending": {"7E8": []}, "stored": {"7E8": ["P0420"]}}` keyed by the id each controller answered on; both empty is the error `no controller answered standard OBD`.
    - `read_identification`: no car read → `{"codingFiles", "hardware", "identification": {"F101": "<hex>", "F18C": "<hex>"}, "module", "name", "serial", "software"}`.
    - `read_coding` without `did`: from `car.latestBackup` → `{"identifiers": {"3000": 2, "3002": 12}, "module": "01", "source": "backup <date ISO 8601>"}`, else the error `no backup holds module 01; ask the owner to run Backup`. With `did`: in the backup → `{"bytes": "0102", "did": "3000", "module": "01", "source": "backup <date>"}`; otherwise the same read as `read_value` (which counts toward its cap) with `"source": "live"`.
    - `read_value`: over the cap → the error `read_value limit of 40 per message reached`; else select, `readDID` → `{"bytes": "0102", "did": "3000", "module": "01"}`; negative `module 01 refused 3000 (0x31)`; silence `module 01 did not answer 3000`.
    - `read_obd`: `obd([0x01, pid])` → `{"answers": {"7E8": "414230B2"}, "pid": "42"}` (each controller's whole answer as hex without spaces); nothing answered is the error `no controller answered PID 42`.
  - `run` throws only what `Diag` throws (`LinkError`, `CancellationError`); every other failure is an `isError` result. It logs `ai: tool <name> <input>` before and `ai: tool <name> → <first 120 characters of the result, or "error: " and the text>` after.
  - `activityLine`, with the module shown as its table name or `0x5B`: `get_vehicle` → `Looked at the car's details`; `read_faults` → `Read <n> fault codes from BDC_BODY3` (`Read standard OBD fault codes` for `"obd"`), an error result → `Could not read fault codes from BDC_BODY3`; `read_identification` → `Looked at FZD__35's identification`; `read_coding` without `did` → `Listed ACSM_5's coding identifiers from the backup`, with `did` → `Read coding identifier 3000 of ACSM_5 (backup)` or `(live)` from the result's `source`; `read_value` → `Read identifier 3000 of ACSM_5`; `read_obd` → `Read standard OBD PID 42`; any error result of the last four → `Could not ` + the same line in lower case after the verb (`Could not read identifier 3000 of ACSM_5`); an invalid input → `Asked for something the app could not read`.

- [ ] **Step 1: Write the failing tests**

The fixture: `func testCar(backup: Backup? = nil) -> MechanicCar` with modules `0x01` `ACSM_5` (identification empty), `0x40` `BDC_BODY3` (identification `[0xF101: [0x00, 0x01, 0x05, 0x00, 0x00, 0x06, 0xC9, 0x18, 0x02, 0x0D], 0xF18C: Array("  SN123  ".utf8)]`, coding files `["CAFD_000006C9_024_002_013"]`, signed), `0x56` `FZD__35`; adapter `AdapterInfo(model: "OBDLink CX r1.0", firmware: "STN2255 v5.6.2", elmVersion: "ELM327 v1.4b")`, VIN `WBY73AW04RFFAKE19`, nickname `i4`. `func testBackup() -> Backup` holds module `0x01` with coding `["3000": "0102", "3002": "AABBCCDDEEFF00112233445566"]`, dated `2026-10-26T21:03:00Z`.

```swift
@Test func toolsAreStrictAndInOrder() {
    #expect(Mechanic.tools.map { $0["name"]?.string } == ["get_vehicle", "read_faults", "read_identification", "read_coding", "read_value", "read_obd", "web_search", "web_fetch"])
    for tool in Mechanic.tools.prefix(6) {
        #expect(tool["strict"]?.bool == true)
        #expect(tool["input_schema"]?["additionalProperties"]?.bool == false)
        #expect(tool["eager_input_streaming"] == nil)
    }
    #expect(Mechanic.tools[3]["input_schema"]?["required"]?.array?.map(\.string) == ["module", "did"])
    #expect(Mechanic.tools[6]["type"]?.string == "web_search_20260209" && Mechanic.tools[7]["type"]?.string == "web_fetch_20260209")
}
@Test func getVehicleDescribesTheCar() async throws {
    let mechanic = Mechanic(diag: Diag(link: FakeLink { _ in ["OK"] }, log: Log()), car: testCar(backup: testBackup()), log: Log())
    let result = try await mechanic.run(ToolCall(id: "t", name: "get_vehicle", input: .object([:])))
    let json = try JSON.parse(Data(result.content.utf8))
    #expect(!result.isError && json["chassis"]?.string == "G26 i4" && json["vin"]?.string == "WBY73AW04RFFAKE19")
    #expect(json["modules"]?.array?.map { $0["address"]?.string } == ["01", "40", "56"])
    #expect(json["modules"]?.array?[1]["signed"]?.bool == true)
    #expect(json["backup"]?["modules"]?.int == 1 && json["backup"]?["date"]?.string == "2026-10-26T21:03:00Z")
}
@Test func readFaultsParsesRefusalsAndSilence() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "40 03 19 02 FF 00 00 00": return ["640 F1 07 59 02 FF 80 1E 2B 2F"]
        case "56 03 19 02 FF 00 00 00": return ["656 F1 03 7F 19 11 00 00 00"]
        case "01 03 19 02 FF 00 00 00": return ["NO DATA"]
        default: return ["OK"] } }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    let ok = try await mechanic.run(ToolCall(id: "t", name: "read_faults", input: .object(["module": .string("40")])))
    #expect(ok.content == #"{"faults":[{"code":"801E2B","status":"2F"}],"module":"40","name":"BDC_BODY3"}"#)
    let refused = try await mechanic.run(ToolCall(id: "t", name: "read_faults", input: .object(["module": .string("56")])))
    #expect(refused == ToolResult("module 56 refused the fault read (0x11)", isError: true))
    let silent = try await mechanic.run(ToolCall(id: "t", name: "read_faults", input: .object(["module": .string("01")])))
    #expect(silent == ToolResult("module 01 did not answer the fault read", isError: true))
}
@Test func readFaultsOBD() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "03": return ["7E8 04 43 01 04 20"]
        case "07": return ["7E8 02 47 00"]
        default: return ["OK"] } }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    let result = try await mechanic.run(ToolCall(id: "t", name: "read_faults", input: .object(["module": .string("obd")])))
    #expect(result.content == #"{"pending":{"7E8":[]},"stored":{"7E8":["P0420"]}}"#)
    let none = Mechanic(diag: Diag(link: FakeLink { _ in ["NO DATA"] }, log: Log()), car: testCar(), log: Log())
    #expect(try await none.run(ToolCall(id: "t", name: "read_faults", input: .object(["module": .string("obd")]))).isError)
}
@Test func readIdentificationReadsNothing() async throws {
    let link = FakeLink { _ in ["OK"] }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    let result = try await mechanic.run(ToolCall(id: "t", name: "read_identification", input: .object(["module": .string("40")])))
    let json = try JSON.parse(Data(result.content.utf8))
    #expect(json["serial"]?.string == "SN123" && json["codingFiles"]?.array?.count == 1)
    #expect(json["identification"]?["F18C"]?.string == "2020534E313233202020")  // "  SN123  " as hex
    #expect(link.sent.isEmpty)
}
@Test func readCodingFromTheBackupThenLive() async throws {
    let link = FakeLink { cmd in cmd == "01 03 22 30 05 00 00 00" ? ["601 F1 04 62 30 05 7B 00 00"] : ["OK"] }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(backup: testBackup()), log: Log())
    let list = try await mechanic.run(ToolCall(id: "t", name: "read_coding", input: .object(["module": .string("01"), "did": .null])))
    #expect(list.content == #"{"identifiers":{"3000":2,"3002":13},"module":"01","source":"backup 2026-10-26T21:03:00Z"}"#)
    let stored = try await mechanic.run(ToolCall(id: "t", name: "read_coding", input: .object(["module": .string("01"), "did": .string("3000")])))
    #expect(stored.content == #"{"bytes":"0102","did":"3000","module":"01","source":"backup 2026-10-26T21:03:00Z"}"#)
    let live = try await mechanic.run(ToolCall(id: "t", name: "read_coding", input: .object(["module": .string("01"), "did": .string("3005")])))
    #expect(live.content == #"{"bytes":"7B","did":"3005","module":"01","source":"live"}"#)
    let noBackup = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    #expect(try await noBackup.run(ToolCall(id: "t", name: "read_coding", input: .object(["module": .string("40"), "did": .null])))
        == ToolResult("no backup holds module 40; ask the owner to run Backup", isError: true))
}
@Test func readValueIsCappedPerMessage() async throws {
    let link = FakeLink { cmd in cmd.hasPrefix("40 03 22") ? ["640 F1 04 62 30 00 01 00 00"] : ["OK"] }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    let call = ToolCall(id: "t", name: "read_value", input: .object(["module": .string("40"), "did": .string("3000")]))
    for _ in 0..<40 { #expect(try await mechanic.run(call).content == #"{"bytes":"01","did":"3000","module":"40"}"#) }
    #expect(try await mechanic.run(call) == ToolResult("read_value limit of 40 per message reached", isError: true))
    mechanic.beginMessage()
    #expect(try await mechanic.run(call).isError == false)
    #expect(link.sent.filter { $0.hasPrefix("40 03 22") }.count == 41)
}
@Test func invalidInputsSendNothingToTheCar() async throws {
    let link = FakeLink { _ in ["OK"] }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    func run(_ name: String, _ input: [String: JSON]) async throws -> ToolResult {
        try await mechanic.run(ToolCall(id: "t", name: name, input: .object(input)))
    }
    #expect(try await run("read_faults", ["module": .string("0x40")]) == ToolResult(#"module must be the two-digit hex address of a listed module, as "40""#, isError: true))
    #expect(try await run("read_faults", ["module": .string("BDC_BODY3")]).isError)
    #expect(try await run("read_faults", ["module": .string("5B")]) == ToolResult("no module at address 5B on this car", isError: true))
    #expect(try await run("read_value", ["module": .string("obd"), "did": .string("3000")]) == ToolResult(#""obd" is only valid for read_faults"#, isError: true))
    #expect(try await run("read_value", ["module": .string("40"), "did": .string("3002h")]) == ToolResult(#"did must be four hex digits, as "3002""#, isError: true))
    #expect(try await run("read_value", ["module": .string("40")]) == ToolResult("missing did", isError: true))
    #expect(try await run("read_obd", ["pid": .string("4")]) == ToolResult(#"pid must be two hex digits, as "42""#, isError: true))
    #expect(try await run("clear_faults", ["module": .string("40")]) == ToolResult("unknown tool clear_faults", isError: true))
    #expect(link.sent.isEmpty)
}
@Test func activityLinesNameTheModule() {
    let car = testCar()
    let faults = ToolCall(id: "t", name: "read_faults", input: .object(["module": .string("40")]))
    #expect(Mechanic.activityLine(for: faults, result: ToolResult(#"{"faults":[{"code":"801E2B","status":"2F"},{"code":"801E2C","status":"08"}],"module":"40","name":"BDC_BODY3"}"#), car: car) == "Read 2 fault codes from BDC_BODY3")
    #expect(Mechanic.activityLine(for: faults, result: ToolResult("module 40 did not answer the fault read", isError: true), car: car) == "Could not read fault codes from BDC_BODY3")
    let value = ToolCall(id: "t", name: "read_value", input: .object(["module": .string("01"), "did": .string("3000")]))
    #expect(Mechanic.activityLine(for: value, result: ToolResult("{}"), car: car) == "Read identifier 3000 of ACSM_5")
    let coding = ToolCall(id: "t", name: "read_coding", input: .object(["module": .string("01"), "did": .string("3005")]))
    #expect(Mechanic.activityLine(for: coding, result: ToolResult(#"{"bytes":"7B","did":"3005","module":"01","source":"live"}"#), car: car) == "Read coding identifier 3005 of ACSM_5 (live)")
    #expect(Mechanic.activityLine(for: ToolCall(id: "t", name: "get_vehicle", input: .object([:])), result: ToolResult("{}"), car: car) == "Looked at the car's details")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter MechanicTests`
Expected: FAIL, `Mechanic` not found.

- [ ] **Step 3: Implement `MechanicCar`, `Mechanic.tools`, validation, the six tools and `activityLine`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Core
git commit -m "Mechanic: the six read-only tools with validation and the read cap"
```

---

### Task 7: Health check, car context and system prompt

**Files:**
- Modify: `Core/Sources/BMWCodingCore/Mechanic.swift`
- Test: `Core/Tests/BMWCodingCoreTests/MechanicTests.swift` (extend)

**Interfaces:**
- Consumes: Task 6's `Mechanic`, `MechanicCar`; Task 4's `DTCParse`; Task 5's `Diag.obd`, `Diag.readFaults`.
- Produces:
  - `public struct HealthCheck: Codable, Equatable, Sendable { public var vin: String; public var nickname: String; public var chassis: String?; public var adapter: Adapter; public var modules: [ModuleHealth]; public var obd: OBDHealth?; public var backup: BackupSummary?; public var readAt: String }` with `public struct Adapter: Codable, Equatable, Sendable { model, firmware: String }`, `public struct ModuleHealth: Codable, Equatable, Sendable { address: String; name, description: String?; signed: Bool; hardware, software, serial: String?; codingFiles: [String]; faults: [Fault]?; faultRead: String? }` (`faults` filled from a positive answer, `faultRead` holds `refused (0x11)`, `no answer` or `unreadable <hex>` otherwise), `public struct Fault: Codable, Equatable, Sendable { code, status: String }`, `public struct OBDHealth: Codable, Equatable, Sendable { storedCodes, pendingCodes: [String: [String]]; supportedPIDs: [String: [String]]; values: [String: [String: String]] }` (every map keyed by the controller id as `7E8`; `values` is PID → the whole answer as hex without spaces), `public struct BackupSummary: Codable, Equatable, Sendable { date: String; modules: Int }`, and `public var contextJSON: String` (pretty-printed, sorted keys, the same bytes every time it is computed).
  - `public func healthCheck(progress: (String) -> Void) async throws -> HealthCheck` on `Mechanic`: for every module of the car in order, `progress("Reading fault codes from <name> …")`, select, `readFaults`, record; then `progress("Reading standard OBD codes …")`, `obd([0x03])` and `obd([0x07])` decoded with `DTCParse.obdCodes` (a controller whose answer does not decode is left out); then `progress("Reading standard OBD values …")`, `obd([0x01, 0x00])`, and for each base in `0x00`, `0x20`, `0x40` (the next only where the previous answer of some controller advertised it) the supported PIDs are read one request each, at most 64 value requests in all, PIDs `0x20` and `0x40` not read twice; `obd` is nil when every standard request got no answer at all. A `LinkError` or a cancel aborts the check and is thrown. `readAt` is now as ISO 8601 UTC whole seconds.
  - `public static func systemPrompt(carContext: String) -> [JSON]`: two `{"type": "text", "text": ...}` blocks and no `cache_control`: the instructions, then `The car, from the health check:\n` + the context JSON.
  - `public static let firstQuestion = "Summarize my car's state from the health check: what matters, what does not, and what you looked up."`
  - `public static let suggestedQuestionsMarker = "Suggested questions:"`
  - The instructions are written by the implementer in plain English from these points, each present: you are a mechanic talking to the car's owner; be concrete and brief; prefer reading the car over guessing; say which module and code you are talking about; when you looked something up, cite it; distinguish what the car reports from what you infer; you cannot change anything about the car, the owner can run Backup and the module scan from the app's steps, and you say so when asked; if the model declines to answer, say so in one line; the six tools by name with when to call each; end a summary with the line `Suggested questions:` followed by up to three lines each starting with `- `, and otherwise never use that line; the car context follows.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func healthCheckReadsEveryModuleThenStandardOBD() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "01 03 19 02 FF 00 00 00": return ["601 F1 03 59 02 FF 00 00 00"]
        case "40 03 19 02 FF 00 00 00": return ["640 F1 07 59 02 FF 80 1E 2B 2F"]
        case "56 03 19 02 FF 00 00 00": return ["656 F1 03 7F 19 11 00 00 00"]
        case "03": return ["7E8 04 43 01 04 20"]
        case "07": return ["NO DATA"]
        case "01 00": return ["7E8 06 41 00 80 00 00 00"]
        case "01 01": return ["7E8 06 41 01 00 07 E5 00"]
        default: return ["OK"] } }
    var steps: [String] = []
    let check = try await Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log()).healthCheck { steps.append($0) }
    #expect(steps == ["Reading fault codes from ACSM_5 …", "Reading fault codes from BDC_BODY3 …", "Reading fault codes from FZD__35 …", "Reading standard OBD codes …", "Reading standard OBD values …"])
    #expect(check.modules.map(\.address) == ["01", "40", "56"])
    #expect(check.modules[0].faults == [] && check.modules[1].faults == [HealthCheck.Fault(code: "801E2B", status: "2F")])
    #expect(check.modules[2].faults == nil && check.modules[2].faultRead == "refused (0x11)")
    let obd = try #require(check.obd)
    #expect(obd.storedCodes == ["7E8": ["P0420"]] && obd.pendingCodes == [:])
    #expect(obd.supportedPIDs == ["7E8": ["01"]] && obd.values == ["7E8": ["01": "41010007E500"]])
    #expect(link.sent.filter { $0.hasPrefix("01 ") && $0.count == 5 } == ["01 00", "01 01"])
    #expect(check.vin == "WBY73AW04RFFAKE19" && check.chassis == "G26 i4")
}
@Test func healthCheckWithoutStandardOBD() async throws {
    let link = FakeLink { cmd in cmd.contains("19 02") || cmd.hasPrefix("0") ? ["NO DATA"] : ["OK"] }  // every car request silent, every AT command OK
    let check = try await Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log()).healthCheck { _ in }
    #expect(check.obd == nil)
    #expect(check.modules.allSatisfy { $0.faultRead == "no answer" })
}
@Test func healthCheckStopsOnALinkError() async throws {
    let link = FakeLink { cmd in cmd.hasPrefix("40 03 19") ? ["CAN ERROR"] : ["OK"] }
    await #expect(throws: LinkError.adapterError("CAN ERROR")) {
        try await Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log()).healthCheck { _ in }
    }
}
@Test func contextIsStableAndSystemPromptHasTwoBlocks() async throws {
    let link = FakeLink { cmd in cmd.contains("19 02") || cmd.hasPrefix("0") ? ["NO DATA"] : ["OK"] }
    let check = try await Mechanic(diag: Diag(link: link, log: Log()), car: testCar(backup: testBackup()), log: Log()).healthCheck { _ in }
    #expect(check.contextJSON == check.contextJSON)
    #expect(check.contextJSON.range(of: "\"adapter\"")!.lowerBound < check.contextJSON.range(of: "\"backup\"")!.lowerBound)
    #expect(check.backup == HealthCheck.BackupSummary(date: "2026-10-26T21:03:00Z", modules: 1))
    let prompt = Mechanic.systemPrompt(carContext: check.contextJSON)
    #expect(prompt.count == 2 && prompt[1]["text"]?.string?.hasSuffix(check.contextJSON) == true)
    #expect(prompt.allSatisfy { $0["cache_control"] == nil })
    for name in ["get_vehicle", "read_faults", "read_identification", "read_coding", "read_value", "read_obd", "Suggested questions:"] {
        #expect(prompt[0]["text"]?.string?.contains(name) == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter MechanicTests`
Expected: FAIL, `healthCheck` not found.

- [ ] **Step 3: Implement `HealthCheck`, `healthCheck`, `systemPrompt`, the constants and the instructions text**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Core
git commit -m "Mechanic: health check, car context and system prompt"
```

---

### Task 8: Conversation store, price table, chips and sources

**Files:**
- Create: `Core/Sources/BMWCodingCore/Conversation.swift`, `Core/Sources/BMWCodingCore/Pricing.swift`, `Core/Tests/BMWCodingCoreTests/ConversationTests.swift`, `Core/Tests/BMWCodingCoreTests/PricingTests.swift`

**Interfaces:**
- Consumes: Task 1's `JSON`, `Usage`; Task 3's `Turn`.
- Produces:
  - `public struct Conversation: Codable, Equatable { public var vin: String; public var started: Date; public var model: String; public var carContext: String; public var messages: [JSON]; public var turns: [TurnRecord]; public init(vin:started:model:carContext:) }` with `public struct TurnRecord: Codable, Equatable { public var messageIndex: Int; public var usage: Usage; public var rounds: Int; public var refused, truncated, stoppedAtRoundCap, stopped: Bool; public var model: String }` (`messageIndex` is the index in `messages` of the owner message that started the turn). `public var totalUsage: Usage` sums the turns.
  - `public struct ConversationStore { public init(directory: URL); public func load(vin: String) -> Conversation?; public func save(_ conversation: Conversation) throws; public func deleteAll() throws }`: one file `Conversations/<vin>.json` inside `directory`, pretty-printed and sorted, dates ISO 8601 on the encoder and decoder, atomic writes, folders created on save; `load` is nil for a missing or undecodable file; `deleteAll` removes the `Conversations` folder (no error when it is missing).
  - `public struct PriceTable: Codable, Equatable, Sendable { public var prices: [String: Price]; public struct Price: Codable, Equatable, Sendable { public var input, output, cacheRead: Double } }` in dollars per million tokens; `public static let standard = PriceTable(prices: ["claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.20), "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.20), "claude-haiku-5-5": Price(input: 0.10, output: 0.50, cacheRead: 0.01)])`; `public func cost(of usage: Usage, model: String) -> Double?`: `(inputTokens × input + cacheCreationInputTokens × 1.25 × input + cacheReadInputTokens × cacheRead + outputTokens × output) / 1_000_000`, nil for a model not in the table. Web searches are not priced.
  - `public enum Chips { public static func split(_ text: String) -> (body: String, questions: [String]) }`: when the text, trimmed, ends with a block that starts with the line `Suggested questions:` followed by one to three lines each starting with `- `, the block is removed from the body (trailing whitespace trimmed) and the questions returned without the dash; otherwise the text is the body and the questions are empty.
  - `public enum Sources { public static func list(in content: [JSON]) -> [Source] }` with `public struct Source: Equatable, Sendable { public var url: String; public var title: String }`: every `web_search_result_location` citation on every `text` block of the content, unique by `url`, in order of first appearance.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func conversationRoundTripsThroughTheStore() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ConversationStore(directory: folder)
    #expect(store.load(vin: "WBY73AW04RFFAKE19") == nil)
    var conversation = Conversation(vin: "WBY73AW04RFFAKE19", started: Date(timeIntervalSince1970: 1_793_000_000), model: "claude-opus-5-5", carContext: "{}")
    conversation.messages = [.object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("hi")])])])]
    conversation.turns = [.init(messageIndex: 0, usage: Usage(inputTokens: 10, outputTokens: 5, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, webSearchRequests: 1, webFetchRequests: 0), rounds: 1, refused: false, truncated: false, stoppedAtRoundCap: false, stopped: false, model: "claude-opus-5-5")]
    try store.save(conversation)
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Conversations/WBY73AW04RFFAKE19.json").path))
    #expect(store.load(vin: "WBY73AW04RFFAKE19") == conversation)
    #expect(conversation.totalUsage.webSearchRequests == 1)
    try store.deleteAll()
    #expect(store.load(vin: "WBY73AW04RFFAKE19") == nil)
    try store.deleteAll()
}
@Test func costUsesTheTable() {
    let usage = Usage(inputTokens: 1000, outputTokens: 500, cacheCreationInputTokens: 100, cacheReadInputTokens: 2000, webSearchRequests: 3, webFetchRequests: 0)
    #expect(abs((PriceTable.standard.cost(of: usage, model: "claude-opus-5-5") ?? 0) - 0.0149) < 1e-12)
    #expect(abs((PriceTable.standard.cost(of: usage, model: "claude-haiku-5-5") ?? 0) - 0.0003825) < 1e-12)
    #expect(PriceTable.standard.cost(of: usage, model: "claude-opus-4-8") == nil)
}
@Test func chipsComeOffTheEnd() {
    let text = "Two faults.\n\nSuggested questions:\n- Is the camera related?\n- What would a dealer charge?\n"
    let (body, questions) = Chips.split(text)
    #expect(body == "Two faults." && questions == ["Is the camera related?", "What would a dealer charge?"])
    #expect(Chips.split("No chips here.").questions.isEmpty)
    #expect(Chips.split("Suggested questions:\n- one\n- two\n- three\n- four").questions.isEmpty)
    #expect(Chips.split("Suggested questions:\nnot a list").body == "Suggested questions:\nnot a list")
}
@Test func sourcesAreUniqueInOrder() {
    func cite(_ url: String) -> JSON { .object(["type": .string("web_search_result_location"), "url": .string(url), "title": .string("T " + url), "encrypted_index": .string("x"), "cited_text": .string("c")]) }
    let content: [JSON] = [
        .object(["type": .string("text"), "text": .string("a"), "citations": .array([cite("https://a"), cite("https://b")])]),
        .object(["type": .string("server_tool_use"), "id": .string("s"), "name": .string("web_search"), "input": .object([:])]),
        .object(["type": .string("text"), "text": .string("b"), "citations": .array([cite("https://a"), cite("https://c")])])]
    #expect(Sources.list(in: content) == [Sources.Source(url: "https://a", title: "T https://a"), Sources.Source(url: "https://b", title: "T https://b"), Sources.Source(url: "https://c", title: "T https://c")])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter "ConversationTests|PricingTests"`
Expected: FAIL, `Conversation` not found.

- [ ] **Step 3: Implement `Conversation.swift` and `Pricing.swift`**

The cost test compares with a tolerance because the quotients are not exact in binary.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Core
git commit -m "Conversation store, price table, chips and sources"
```

---

### Task 9: App: the fifth step, Keychain, settings and the AI flow state

**Files:**
- Modify: `App/Flow.swift`, `App/VynscopeApp.swift`
- Create: `App/Keychain.swift`, `App/AIFlow.swift`, `App/AISettingsView.swift`
- Build: `make project`, then `xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build` and the same with `-destination 'generic/platform=iOS Simulator'`.

**Interfaces:**
- Consumes: everything from Tasks 1 to 8; phase 1's `Flow` (`diag`, `vin`, `car`, `adapter`, `modules`, `busy`, `log`, `appFolder()`, `latestBackup()`, `discover()`, `describe(_:)`).
- Produces:
  - `Step` gains `case ai` after `backup`, title `"AI Mechanic"`, and `var indicatorLabel: String`: `"\(rawValue + 1) \(title)"` for the first four, `"✦ AI"` for `.ai`; `StepIndicator` shows `indicatorLabel`. `canGoNext`: `.backup` becomes `vin != nil`, `.ai` is `true`. `next()` from `.ai` goes to `.connect` (Done), as the existing arithmetic does. The toolbar's last button reads `Done` on `.ai`, `Next` elsewhere. `FlowView`'s switch gets `case .ai: AIStep()` (the view comes in Task 10; this task adds a placeholder `AIStep` showing `Text("AI")` so the build is green).
  - `enum Keychain { static func apiKey() -> String?; static func setAPIKey(_ key: String) throws; static func deleteAPIKey() throws }` in `App/Keychain.swift`: a generic password, `kSecAttrService` `com.smidley.vynscope`, `kSecAttrAccount` `anthropic-api-key`, `kSecAttrAccessible` `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `SecItemCopyMatching` / `SecItemAdd` / `SecItemUpdate` / `SecItemDelete`; no `kSecUseDataProtectionKeychain`, so the Mac uses the login keychain without a keychain-access-group entitlement. Errors are `struct KeychainError: Error { let status: OSStatus }`.
  - `struct AISettings: Codable, Equatable { var model = "claude-opus-5-5"; var effort = "medium"; var prices = PriceTable.standard }` with `static let models = [("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-haiku-5-5", "Haiku 5.5")]`, `static let efforts = ["low", "medium", "high"]`, `static func load() -> AISettings` (JSON in `UserDefaults.standard` key `aiSettings`, defaults when missing or undecodable), `func save()`.
  - `@Observable @MainActor final class AIFlow` in `App/AIFlow.swift`, created in `VynscopeApp.init` next to `Flow` (both `@State` properties declared without initial values and assigned in `init`, per the SDK 27 `@State` macro rule) and put in the environment:
    - `enum Phase: Equatable { case idle, checking(String), ready, answering }`; `private(set) var phase: Phase`; `private(set) var conversation: Conversation?`; `private(set) var streaming: String` (the assistant text of the turn in progress); `private(set) var activity: [String]` (that turn's activity lines); `var error: String?`; `var settings: AISettings`; `private(set) var hasKey: Bool`; `init(flow: Flow)` (held `unowned`).
    - `func enter() async`: nothing when `flow.diag == nil` or `flow.vin == nil`; otherwise loads `ConversationStore(directory: flow.appFolder()).load(vin:)` into `conversation` and, when there is none, runs `healthCheck()`.
    - `func healthCheck() async`: `error = nil`; when `flow.modules.isEmpty`, `await flow.discover()` first and stop with the flow's error if the list is still empty; then under `flow.busy` (the `Still working` guard as `Flow` does), with the screen kept awake as `Flow.backup` does (`beginActivity` and `isIdleTimerDisabled` on iOS), `phase = .checking("Reading fault codes …")`, `Mechanic(diag:car:log:).healthCheck { phase = .checking($0) }`, then `conversation = Conversation(vin:started:model:carContext:)` with the owner message `Mechanic.firstQuestion` appended, saved, and `runTurn(effort: "high")`. An error leaves `conversation` nil, `phase = .idle` and `error` set with `Flow.describe`.
    - `func send(_ text: String)`: appends `{"role": "user", "content": [{"type": "text", "text": text}]}` to the conversation and runs `runTurn(effort: settings.effort)` in `turnTask`.
    - `runTurn(effort:)`: requires `flow.diag`, `flow.vin`, `flow.adapter` and a key, else `error`; holds `flow.busy` and the screen awake for its whole duration; `phase = .answering`, `streaming = ""`, `activity = []`; builds `MechanicCar(vin: flow.vin, nickname: flow.car?.nickname ?? "", adapter: flow.adapter, modules: flow.modules, latestBackup: flow.latestBackup())`, a `Mechanic` (with `beginMessage()`), and a `ClaudeClient(transport: URLSessionTransport(), apiKey: key, log: flow.log)`; copies `conversation.messages`, calls `client.run(messages:system:tools:model:effort:runTool:onUpdate:)` with `Mechanic.systemPrompt(carContext: conversation.carContext)`, `Mechanic.tools`, `settings.model`; `runTool` runs the mechanic's tool and appends `Mechanic.activityLine` to `activity`; `onUpdate` appends `.text` deltas to `streaming` and, for a `.block` whose type is `server_tool_use`, appends `Searched the web: "<input.query>"` for `web_search` or `Fetched <input.url>` for `web_fetch`. On return: `conversation.messages` takes the loop's messages, a `TurnRecord` is appended (`messageIndex` of the owner message, the turn's usage, rounds, flags, `stopped: false`, the model), the conversation is saved, `phase = .ready`. On `CancellationError`: when `streaming` is not empty an assistant message with that one text block is appended; a `TurnRecord` with `stopped: true` and zero usage is appended; saved; `phase = .ready`. On `ClaudeError.api`: `error = "API error (<type>): <message>"`; on `ClaudeError.badToolInput`: `error = "The model sent an unreadable tool request; ask again"`; on `ClaudeError.network`: `error = "No connection to Anthropic: <message>"`; on anything else `Flow.describe`; in every error case the conversation is saved as it stands and `phase = .ready`.
    - `func stop()` cancels `turnTask` (a health check in progress too). `func newConversation() async`: deletes this VIN's file through the store (remove the file), sets `conversation = nil`, runs `healthCheck()`. `func clearConversations()`: `store.deleteAll()`, `conversation = nil`, `phase = .idle`. `func saveKey(_ key: String)`: trimmed, `Keychain.setAPIKey`, `hasKey = true`; `func removeKey()`. `func saveSettings()`.
    - `var totalCost: Double?`: `settings.prices.cost(of:model:)` summed over the conversation's turns by each turn's model, nil when any turn's model is not priced.
  - `struct AISettingsView: View` in `App/AISettingsView.swift`, presented as a sheet: a `Form` with sections `API key` (a `SecureField("Anthropic API key")` bound to local state, `Save key`, a line `A key is saved` or `No key saved`, `Remove key`), `Model` (`Picker` over `AISettings.models`), `Effort for chat turns` (`Picker` over `AISettings.efforts`; footer: `The health-check summary always uses high.`), `Prices, dollars per million tokens` (for each of the three models three `TextField`s with `value:` and `format: .number` for input, output and cache read), `Privacy` (the exact sentence from Global Constraints), and `Conversations` (`Clear conversations` behind a `confirmationDialog`). Every change calls `ai.saveSettings()`. A Done button closes it.

- [ ] **Step 1: Make the step, Keychain, settings and `AIFlow` changes, with the placeholder `AIStep`**

- [ ] **Step 2: Build for the Mac and the simulator**

Run: `make project && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build && xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet build`
Expected: both builds succeed with no warnings in `App/`.

- [ ] **Step 3: Check the settings sheet on the Mac without a car**

Run: `make mac`; open the AI step from a disconnected state. The step indicator reads `1 Connect · 2 Car · 3 Modules · 4 Backup · ✦ AI`; the placeholder shows; Settings opens from the toolbar gear once Task 10 wires it (for this task, temporarily present it from the placeholder), saving a key shows `A key is saved` and survives a relaunch, `Remove key` clears it. Nothing is logged with the key: `grep -c sk-ant ~/Documents/Vynscope/log.txt` prints 0.

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "App: AI step, Keychain, AI settings and the AI flow state"
```

---

### Task 10: App: the AI step and the chat

**Files:**
- Create: `App/AIStep.swift`, `App/ChatView.swift`
- Modify: `App/AIFlow.swift` only if a binding is missing.

**Interfaces:**
- Consumes: Task 9's `AIFlow`, `AISettings`, `AISettingsView`; Task 8's `Chips`, `Sources`, `PriceTable`; Task 6's `Mechanic.activityLine`; Task 7's `Mechanic.firstQuestion`.
- Produces:
  - `struct AIStep: View`: `.task { await ai.enter() }`; `.onChange(of: flow.step) { if flow.step != .ai { ai.stop() } }`. Body: without a key, `Enter your Anthropic API key in Settings to switch on the AI mechanic.` and a `Settings` button; without `flow.diag`, `Not connected`; `phase == .checking(step)` shows a `ProgressView` with `step` and a `Stop` button; `phase == .idle` with no conversation shows a `Run health check` button and `ai.error` in red; otherwise `ChatView`. Toolbar: a gear opening `AISettingsView` as a sheet, and a `New conversation` button (confirmation dialog, then `ai.newConversation()`). Navigation title `AI Mechanic`.
  - `struct ChatView: View`: a header line with the running total (`Total $0.0149 · 3 turns`, `Total $? …` when a turn's model is unpriced), a `ScrollView` of entries built from `ai.conversation`, the live turn, and an input bar.
    - Entries, from `conversation.messages` in order: a user message whose content is a `text` block → a right bubble, except the message at index 0 (the fixed first question), which is not shown; a user message of `tool_result` blocks → nothing; an assistant message → for each block in order: `text` → a left bubble (`Text(.init(text))` so inline markdown renders), the last text block of the last assistant message of the conversation shows its body with `Chips.split` and its questions as tappable chips (`Button` with capsule style) that call `ai.send`; `tool_use` → an activity line (caption, secondary) from `Mechanic.activityLine` with the `tool_result` of the same `tool_use_id` in the following user message (`…` when there is none); `server_tool_use` → `Searched the web: "<query>"` or `Fetched <url>` as a `Link` when it is a URL; `fallback` → `Answered by a fallback model`; other types nothing. After the last text block of an assistant message, its sources: `Sources.list(in:)` numbered from 1 as `Link("1. <title>", destination:)`. After the last message of each turn (the next turn's `messageIndex`, or the end), the usage line from its `TurnRecord`: `<in> in · <out> out · <cached> cached · $<cost to 4 decimals> · <n> searches` with the searches part omitted when 0 and `$?` for an unpriced model, then in orange when set: `The model declined to answer this` (refused), `The answer was cut short at the length limit` (truncated), `Stopped after 12 tool rounds` (stoppedAtRoundCap), `Stopped` (stopped).
    - The live turn (`phase == .answering`): `ai.activity` lines, then `ai.streaming` as a left bubble when not empty, else a `ProgressView("Thinking…")`.
    - The input bar: `TextField("Ask the mechanic…")` (submit sends), `Send` disabled while answering or when the trimmed text is empty, `Stop` shown while answering. `ai.error` in red above the bar.
    - Scrolls to the bottom whenever the message count, `ai.streaming` or `ai.activity` changes (`ScrollViewReader`, an anchor view at the end).
  - The Mac uses the same views in the main window; the Log window shows the adapter traffic as for the manual steps (nothing to add).

- [ ] **Step 1: Write `AIStep` and `ChatView`, replacing the placeholder**

- [ ] **Step 2: Build for the Mac and the simulator**

Run: the two `xcodebuild` commands of Task 9.
Expected: both succeed.

- [ ] **Step 3: Check the dry states on the Mac**

Run: `make mac`. Without a key: the key notice and Settings. With a key and no adapter: `Not connected`. These are the only states reachable without the car; the rest is Task 11.

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "App: AI Mechanic step and chat"
```

---

### Task 11: In-car verification and corrections (Scott, i4)

**Files:**
- Modify: whatever the car corrects, most likely `Core/Sources/BMWCodingCore/ELM.swift` (`obdSequence`, `bmwSequence`), `Core/Sources/BMWCodingCore/DTC.swift` (the `0x19` record layout), `Core/Sources/BMWCodingCore/Mechanic.swift` (the OBD PID loop), the prompt text, and the matching tests.

- [ ] **Step 1: Switch AI mode on**

Ignition on, Connect, Car, Modules (let the scan finish), Backup (one may exist), Next to `✦ AI`. The health check runs with its progress line through every module, then standard OBD. The summary streams in and names the real fault codes on the car or says there are none. Check the Log: `0x19 0x02 FF` to every module; the standard OBD requests `03`, `07`, `01 00` and only PIDs the car advertised; the switch commands `ATCAF1`, `ATFCSM 0`, `ATAR`, `ATSH 7DF` before and `ATCAF0`, `ATFCSM 1`, `ATSH 6F1`, `ATFCSH 6F1`, `ATCRA`, `ATFCSD` after. If any answers `?` or the car stays silent on `7DF`, note the exact lines; the sequences are first guesses.

- [ ] **Step 2: Check the fault records against the car**

If the summary's codes look wrong (a status byte where a code digit should be, codes shifted by one byte), copy the `59 02 …` frames from the Log and fix `DTCParse.bmwFaults` and its test to the real layout.

- [ ] **Step 3: Ask about a code**

Ask `What does <a code from the summary> mean and how do I fix it?`. The answer carries at least one numbered source, the source opens, the activity lines show the search and any reads. Ask a question that needs a live value; the chat shows `Read identifier …` and the Log shows the `0x22` read.

- [ ] **Step 4: Ask for a change**

Ask `Turn off the seat belt chime` and `Clear the fault codes`. The mechanic explains and changes nothing; the Log shows only adapter setup, `0x22`, `0x19`, `0x3E`, `0x10 0x03` and the standard OBD requests. Note any line that is not one of those.

- [ ] **Step 5: Cost and privacy**

After a turn, compare the usage line with the Log's `ai:` usage note; the running total adds up. `grep -c <the key's first 12 characters> ~/Documents/Vynscope/log.txt` prints 0.

- [ ] **Step 6: The iPhone**

Repeat Step 1 and Step 3 on the iPhone; the saved conversation on the Mac is per device, so the iPhone runs its own health check. The screen stays awake during the check and a turn.

- [ ] **Step 7: Corrections**

Every correction becomes a code change with its test, `swift test` green, both builds green, and a commit `In-car corrections: <what changed>`. Record what the i4 answers on standard OBD in the design doc's "Left to the builder" section.

- [ ] **Step 8: Failures, fetched pages, Stop and a model switch**

Five checks; note what the chat and the Log show for each:
1. Enter a wrong key first. The summary fails with `Failed: API error (authentication_error): …` under it and `Try again` above the input bar. Fix the key in Settings (the error clears), press `Try again`, and the summary streams in.
2. Ask a question the mechanic answers from a fetched page (a `Fetched <url>` line in the activity). The page is among the numbered sources under the answer and opens.
3. Press Stop during a round with several tool calls. No call runs after Stop (the Log shows no adapter command after it), the chat keeps the reads made so far and the text streamed, and the usage line says `Stopped`.
4. Switch the model in Settings mid-conversation and ask again. Note whether the API accepts the old model's thinking blocks; if it refuses them, note the error: they then have to be stripped on a switch.
5. Confirm the Log carries the API error text (`ai: error 401 authentication_error: …` from check 1) and never the key: `grep -c <the key's first 12 characters> ~/Documents/Vynscope/log.txt` prints 0.

---

## Spec coverage

| Spec requirement | Task |
|---|---|
| Fifth step `✦ AI`, enabled once connected with a VIN; health check on first entry; chat with the summary streaming | 7, 9, 10 |
| Chat: bubbles, activity line per read, numbered sources that open, usage and cost line, chips, Stop, persistence per car, New conversation, re-run on request | 8, 9, 10 |
| Settings: key (masked, Keychain), model list, effort, price table, privacy sentence, Clear conversations | 9 |
| Mac identical, log window shows the traffic | 10 |
| Health check contents and the car context block | 7 |
| The six tools, their inputs and results, the 40-read cap, the web tools | 6 |
| System prompt points, fixed first turn | 7 |
| Endpoint, headers, model, effort, streaming, `max_tokens`, no prefill, no `temperature` | 2 |
| Tool loop, 12 rounds, `is_error`, validation before running, `tool_choice` auto | 3, 6 |
| `pause_turn`, refusal with `fallbacks: "default"` and the one-line notice | 3, 10 |
| Caching breakpoints, the cache-miss log note | 2, 3 |
| Retries on 429/500/529, one-line errors otherwise, key never logged | 2 |
| Allowed wire list with `0x19` and standard OBD; the addressing switch | 5 |
| DTC layouts, standard OBD decoding | 4 |
| No test calls Anthropic | 2, 3 (FakeTransport), all |
| What Scott verifies | 11 |
