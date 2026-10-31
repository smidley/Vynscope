import Foundation

/// The car the mechanic works on, as the app knows it: what the first steps read, and its newest backup.
public struct MechanicCar: Equatable, Sendable {
    public var vin: String
    public var nickname: String
    public var adapter: AdapterInfo
    public var modules: [DiscoveredModule]
    public var latestBackup: Backup?

    public init(
        vin: String, nickname: String, adapter: AdapterInfo, modules: [DiscoveredModule], latestBackup: Backup?
    ) {
        self.vin = vin
        self.nickname = nickname
        self.adapter = adapter
        self.modules = modules
        self.latestBackup = latestBackup
    }
}

/// What the health check found: the car context the model starts from, sent as JSON in the system prompt.
public struct HealthCheck: Codable, Equatable, Sendable {
    public var vin: String
    public var nickname: String
    public var chassis: String?
    public var adapter: Adapter
    public var modules: [ModuleHealth]
    /// `nil` when no controller answered any standard request, or when the adapter failed during them.
    public var obd: OBDHealth?
    /// How the adapter failed during the standard requests, which ended them: its error line, `timeout` or
    /// `disconnected`. `nil` when they ran through.
    public var obdError: String?
    public var backup: BackupSummary?
    /// When the check ran: ISO 8601, UTC, whole seconds.
    public var readAt: String

    public struct Adapter: Codable, Equatable, Sendable {
        public var model, firmware: String
    }

    /// A module as the scan found it, with its fault codes.
    public struct ModuleHealth: Codable, Equatable, Sendable {
        public var address: String
        public var name, description: String?
        public var signed: Bool
        public var hardware, software, serial: String?
        public var codingFiles: [String]
        /// From a positive answer to the fault read; otherwise `nil` and `faultRead` says why.
        public var faults: [Fault]?
        /// `refused (0x11)`, `no answer` or `unreadable <hex>`.
        public var faultRead: String?
    }

    public struct Fault: Codable, Equatable, Sendable {
        public var code, status: String
    }

    /// Standard OBD-II, every map keyed by the CAN id a controller answered on, as `7E8`.
    public struct OBDHealth: Codable, Equatable, Sendable {
        public var storedCodes, pendingCodes: [String: [String]]
        /// The mode 01 PIDs each controller advertised, as two hex digits.
        public var supportedPIDs: [String: [String]]
        /// PID to the controller's whole answer as hex.
        public var values: [String: [String: String]]
    }

    public struct BackupSummary: Codable, Equatable, Sendable {
        public var date: String
        public var modules: Int
    }

    /// Whether nothing in the car answered: every module's fault read got no answer and no controller answered the
    /// standard requests, which is what an ignition that is off looks like. There is nothing for the mechanic to say then.
    public var nothingAnswered: Bool {
        modules.allSatisfy { $0.faults == nil && $0.faultRead == "no answer" } && obd == nil
    }

    /// The check as pretty-printed JSON with sorted keys: the same bytes every time, so the prompt caches.
    public var contextJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // Cannot fail: everything in a check is a string, a number, a flag, or a collection of them.
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}

/// The mechanic's reach into the car: six read-only tools for the model, each input checked before anything is
/// sent, and a cap on live reads per owner message. Every call and its result go to the log.
public final class Mechanic {
    /// Live reads of a data identifier (`read_value`, and `read_coding` of one the backup lacks) per owner message.
    public static let readValueCap = 40

    /// The tools every request declares: the six read-only ones, then the server-side web search and web fetch.
    public static let tools: [JSON] = [
        tool(
            "get_vehicle",
            "The car as the app knows it: VIN, nickname, chassis, adapter, every module with its address, name, "
                + "description, signed flag, hardware, software and coding files, and whether a backup exists. Call "
                + "this when you need a module's address or want to know what is on the car."),
        tool(
            "read_faults",
            #"The fault codes stored in one module (UDS 0x19 0x02), or with module "obd" the standard OBD-II stored "#
                + "and pending codes from every controller that answers. The health check already holds every "
                + "module's codes; call this again only to see whether they changed.",
            [("module", property(moduleShape + #", or "obd" for the standard OBD-II codes"#))]),
        tool(
            "read_identification",
            "What a module said about itself during the scan: its identification identifiers as hex and the parsed "
                + "coding-file names. Reads nothing from the car. Call this to look at a module's hardware and "
                + "software versions.",
            [("module", property(moduleShape))]),
        tool(
            "read_coding",
            "A module's coding data. Without did: the identifiers in the latest backup and their sizes in bytes. "
                + "With did: that identifier's bytes as hex from the latest backup, or a live read when the backup "
                + "does not have it. The answer says which. Call this to look at how an option is coded.",
            [("module", property(moduleShape)), ("did", property(didShape, orNull: true))]),
        tool(
            "read_value",
            "A live read of one data identifier (UDS 0x22) on one module, bytes as hex, at most \(readValueCap) per "
                + "owner message. Call this for live values or for identifiers the backup does not have.",
            [("module", property(moduleShape)), ("did", property(didShape))]),
        tool(
            "read_obd",
            "One standard OBD-II mode 01 PID, the raw answer as hex per responding controller, for you to decode. "
                + "Call this for live engine-side values; an electric car may answer nothing.",
            [("pid", property(#"two hex digits, as "42""#))]),
        .object(["type": .string("web_search_20260209"), "name": .string("web_search")]),
        .object(["type": .string("web_fetch_20260209"), "name": .string("web_fetch")]),
    ]

    /// The owner message every conversation starts with: the summary of the health check.
    public static let firstQuestion =
        "Summarize my car's state from the health check: what matters, what does not, and what you looked up."
    /// The line a summary's suggested questions follow, which the chat shows as chips.
    public static let suggestedQuestionsMarker = "Suggested questions:"

    private static let moduleShape = #"two hex digits of the diagnostic address, as "40""#
    private static let didShape = #"four hex digits, as "3002""#

    private let diag: Diag
    private let car: MechanicCar
    private let log: Log
    /// Live reads since `beginMessage()`.
    private var liveReads = 0

    public init(diag: Diag, car: MechanicCar, log: Log) {
        self.diag = diag
        self.car = car
        self.log = log
    }

    /// Starts an owner message: the live-read count starts again from zero.
    public func beginMessage() {
        liveReads = 0
    }

    /// Runs one tool call. An input that does not pass the checks, an unknown tool, a module that refuses or does
    /// not answer, and a read over the cap all answer with `isError`; only what `Diag` throws (`LinkError`,
    /// `DiagError`, a cancel) is thrown. A call that comes after a cancel throws `CancellationError` before anything
    /// is checked, logged or sent, so Stop also holds between the calls of one round.
    public func run(_ call: ToolCall) async throws -> ToolResult {
        try Task.checkCancellation()
        log.note("ai: tool \(call.name) \(String(decoding: call.input.encoded(), as: UTF8.self))")
        let result: ToolResult
        do {
            result = ToolResult(String(decoding: try await answer(call).encoded(), as: UTF8.self))
        } catch let failure as ToolFailure {
            result = ToolResult(failure.text, isError: true)
        }
        let shown = result.isError ? "error: " + result.content : String(result.content.prefix(120))
        log.note("ai: tool \(call.name) → \(shown)")
        return result
    }

    /// The health check a conversation starts from: every module's fault codes, in order, then standard OBD-II,
    /// with `progress` told each step. A module that refuses or does not answer is recorded and the check goes on;
    /// a `LinkError` during the module reads, a `DiagError` at any step (another car, a silent car, a link that kept
    /// dropping), a link that gave up (`LinkError.disconnected`) at any step, or a cancel anywhere, ends it and is
    /// thrown. An adapter error or a timeout during the standard requests ends only them: the check keeps the
    /// modules and says why in `obdError`.
    public func healthCheck(progress: (String) -> Void) async throws -> HealthCheck {
        var modules: [HealthCheck.ModuleHealth] = []
        for (index, module) in car.modules.enumerated() {
            try Task.checkCancellation()  // between two modules, so no answer is left unread
            progress("Reading fault codes · \(index + 1) of \(car.modules.count) · \(Self.name(of: module))")
            modules.append(try await health(of: module))
        }
        var obd: HealthCheck.OBDHealth?, obdError: String?
        do {
            obd = try await standardOBD(progress: progress)
        } catch let error as LinkError {
            obdError = switch error {
            case .adapterError(let line): line
            case .timeout: "timeout"
            case .disconnected, .reconnected: throw error  // the link gave up; `Diag` restores after a reconnect
            }
        }
        return HealthCheck(
            vin: car.vin, nickname: car.nickname, chassis: Self.chassis(forVIN: car.vin),
            adapter: .init(model: car.adapter.model, firmware: car.adapter.firmware), modules: modules, obd: obd,
            obdError: obdError,
            backup: car.latestBackup.map { .init(date: $0.date.formatted(.iso8601), modules: $0.modules.count) },
            readAt: Date.now.formatted(.iso8601))
    }

    /// The line the chat shows for a call and its result, a module named by its table name or as `0x5B`.
    public static func activityLine(for call: ToolCall, result: ToolResult, car: MechanicCar) -> String {
        guard let request = try? Self.request(call, car: car) else {
            return "Asked for something the app could not read"
        }
        let answer = result.isError ? nil : try? JSON.parse(Data(result.content.utf8))
        let count = answer?["faults"]?.array?.count ?? 0
        // ` (live)`, or ` (backup)` from `backup <date>`.
        let source = answer?["source"]?.string?.split(separator: " ").first.map { " (\($0))" } ?? ""
        // How the line opens when the call worked and after `Could not` when it failed, then what it was done to.
        let (done, tried, what): (String, String, String) = switch request {
        case .vehicle: ("Looked at", "look at", "the car's details")
        case .faults(let module?):
            ("Read \(count)", "read", "fault \(count == 1 ? "code" : "codes") from \(name(of: module))")
        case .faults(nil): ("Read", "read", "standard OBD fault codes")
        case .identification(let module): ("Looked at", "look at", "\(name(of: module))'s identification")
        case .coding(let module, nil): ("Listed", "list", "\(name(of: module))'s coding identifiers from the backup")
        case .coding(let module, let did?):
            ("Read", "read", "coding identifier \(identifier(did)) of \(name(of: module))\(source)")
        case .value(let module, let did): ("Read", "read", "identifier \(identifier(did)) of \(name(of: module))")
        case .obd(let pid): ("Read", "read", "standard OBD PID \(hex([pid]))")
        }
        return result.isError ? "Could not \(tried) \(what)" : "\(done) \(what)"
    }

    /// The chassis a VIN belongs to, as far as the app knows: `G26 i4` for a VIN starting `WBY73`.
    public static func chassis(forVIN vin: String) -> String? {
        vin.hasPrefix("WBY73") ? "G26 i4" : nil
    }

    /// The web tools the model has, which the prompt names: Anthropic's search and fetch, or OpenAI's search alone.
    public nonisolated enum WebTools: Equatable, Sendable {
        case searchAndFetch
        case search
    }

    /// The system prompt: the instructions, then the car context after `The car, from the health check:`, as two
    /// text blocks without cache markers (the client marks the last). The instructions name the `web` tools.
    public static func systemPrompt(carContext: String, web: WebTools = .searchAndFetch) -> [JSON] {
        [instructions(web: web), "The car, from the health check:\n" + carContext].map { text in
            .object(["type": .string("text"), "text": .string(text)])
        }
    }

    /// A message the owner wrote, as `provider`'s API takes it: one text block, or one `input_text` part.
    public static func ownerMessage(_ text: String, provider: Provider) -> JSON {
        switch provider {
        case .anthropic:
            .object([
                "role": .string("user"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ])
        case .openai:
            .object([
                "type": .string("message"), "role": .string("user"),
                "content": .array([.object(["type": .string("input_text"), "text": .string(text)])]),
            ])
        }
    }

    /// Whether `message`, in `provider`'s shape, is one the owner wrote: a user message with text, not one that
    /// carries tool results. A Responses message may leave out its `type` and may carry its content as plain text.
    public static func isOwnerMessage(_ message: JSON, provider: Provider) -> Bool {
        guard message["role"]?.string == "user" else { return false }
        let content = message["content"]
        switch provider {
        case .anthropic:
            return (content?.array ?? []).contains { $0["type"]?.string == "text" }
        case .openai:
            let type = message["type"]
            return (type == nil || type == .string("message"))
                && (content?.string != nil || (content?.array ?? []).contains { $0["type"]?.string == "input_text" })
        }
    }

    /// Who the model is, how it answers, its tools, and the line its suggested questions follow.
    private static func instructions(web: WebTools) -> String {
        // How the line of the tools that names the web tools starts, by the tools the provider has.
        let webTools = switch web {
        case .searchAndFetch: "web_search and web_fetch: use them"
        case .search: "web_search: use it"
        }
        return """
        You are a mechanic talking with the owner of this car through an app on their phone or Mac. The app is \
        connected to the car through an OBD-II adapter and reads the car for you with the tools below.

        How to answer:
        - Be concrete and brief. Write plain sentences and short lists; **bold** and `code` show as such, headings \
        and tables do not.
        - Prefer reading the car over guessing: when a fresh read would settle a question, make it.
        - Say which module and which code you are talking about: the module by name and address (BDC_BODY3 at 40), \
        the code as the car reports it (801E2B, P0420).
        - Keep what the car reports apart from what you infer from it. Say when you are guessing, and do not state \
        what a code means as fact unless you know it or looked it up.
        - When something you say comes from a web search or a fetched page, cite it.
        - You can only read. You cannot change anything about the car (no coding, no clearing of fault codes, no \
        resets or actuator tests), and you never claim to have. When the owner asks for a change, say plainly that \
        you cannot make it, and explain what it would involve. Nor can you run the module scan or a backup: the \
        owner runs them from the app's Modules and Backup steps. Say so when asked, and suggest them when fresher \
        data would help.
        - If you decline to answer something, say so in one line.

        Tools:
        - get_vehicle: the car, its adapter and every module with its address. Call it when you need an address or \
        want to see what is on the car.
        - read_faults: one module's fault codes, or with "obd" the standard OBD-II codes. The health check below \
        already holds every module's codes; call it only to see whether they changed.
        - read_identification: what a module said about itself in the scan (identifiers, hardware and software \
        versions, coding files); it reads nothing from the car. Call it to look at a module's versions.
        - read_coding: a module's coding identifiers in the latest backup, or one identifier's bytes, from the \
        backup or read live when the backup lacks it. Call it to see how an option is coded.
        - read_value: a live read of one data identifier on one module. Call it for live values; at most \
        \(readValueCap) per owner message, so read only what you need.
        - read_obd: one standard OBD-II mode 01 PID, the raw answer of every controller that answers, for you to \
        decode. Call it for live engine-side values; an electric car may answer nothing.
        - \(webTools) to look up what a code means, known faults and service notes for this \
        car.

        End a summary with a line that reads exactly "\(suggestedQuestionsMarker)", then one to three short \
        questions the owner might ask next, each on its own line starting with "- ", and nothing after them. Never \
        write that line otherwise.

        The health check's findings follow as JSON: the car, each module with its fault codes (faults, or faultRead \
        saying why there are none), standard OBD-II codes and values by controller (obd, left out when no \
        controller answered), and the latest backup.
        """
    }

    /// A tool call whose input passed the checks.
    private enum Request {
        case vehicle
        /// `nil` is standard OBD.
        case faults(DiscoveredModule?)
        case identification(DiscoveredModule)
        /// Without an identifier: the list from the backup.
        case coding(DiscoveredModule, did: UInt16?)
        case value(DiscoveredModule, did: UInt16)
        case obd(pid: UInt8)
    }

    /// What `call` asks for once its input is valid; throws why it is not.
    private static func request(_ call: ToolCall, car: MechanicCar) throws -> Request {
        let input = call.input
        func module() throws -> DiscoveredModule {
            if input["module"] == .string("obd") { throw ToolFailure(#""obd" is only valid for read_faults"#) }
            let address: UInt8 = try hexInput(
                "module", in: input, else: #"module must be the two-digit hex address of a listed module, as "40""#)
            guard let module = car.modules.first(where: { $0.address == address }) else {
                throw ToolFailure("no module at address \(hex([address])) on this car")
            }
            return module
        }
        func did() throws -> UInt16 { try hexInput("did", in: input, else: #"did must be four hex digits, as "3002""#) }
        switch call.name {
        case "get_vehicle": return .vehicle
        case "read_faults": return try .faults(input["module"] == .string("obd") ? nil : module())
        case "read_identification": return try .identification(module())
        case "read_coding": return try .coding(module(), did: input["did"] == .null ? nil : did())
        case "read_value": return try .value(module(), did: did())
        case "read_obd": return try .obd(pid: hexInput("pid", in: input, else: #"pid must be two hex digits, as "42""#))
        default: throw ToolFailure("unknown tool \(call.name)")
        }
    }

    /// The input's `key` as exactly the hex digits of a `T`, either case (two for a byte, four for an identifier).
    /// Throws `missing <key>` when it is absent or null, and `shape` when it is anything else.
    private static func hexInput<T: FixedWidthInteger>(_ key: String, in input: JSON, else shape: String) throws -> T {
        guard let value = input[key], value != .null else { throw ToolFailure("missing \(key)") }
        // The digit check also keeps out the sign that `init(_:radix:)` accepts.
        guard let text = value.string, text.count == T.bitWidth / 4, text.allSatisfy(\.isHexDigit),
              let number = T(text, radix: 16) else { throw ToolFailure(shape) }
        return number
    }

    private func answer(_ call: ToolCall) async throws -> JSON {
        switch try Self.request(call, car: car) {
        case .vehicle: vehicle()
        case .faults(let module?): try await faults(of: module)
        case .faults(nil): try await standardFaults()
        case .identification(let module): identification(of: module)
        case .coding(let module, nil): try codingList(of: module)
        case .coding(let module, let did?): try await coding(did, of: module)
        case .value(let module, let did): Self.reading(did, of: module, bytes: try await liveRead(did, of: module))
        case .obd(let pid): try await standardValue(pid)
        }
    }

    private func vehicle() -> JSON {
        .object([
            "vin": .string(car.vin), "nickname": .string(car.nickname),
            "chassis": Self.text(Self.chassis(forVIN: car.vin)),
            "adapter": .object(["model": .string(car.adapter.model), "firmware": .string(car.adapter.firmware)]),
            "modules": .array(car.modules.map { module in
                .object([
                    "address": .string(Self.hex([module.address])), "name": Self.text(module.name),
                    "description": Self.text(module.description), "signed": .bool(module.signed),
                    "hardware": Self.text(module.hardware), "software": Self.text(module.software),
                    "codingFiles": Self.strings(module.codingFiles),
                ])
            }),
            "backup": car.latestBackup.map { backup in
                .object([
                    "date": .string(backup.date.formatted(.iso8601)), "modules": .number(Double(backup.modules.count)),
                ])
            } ?? .null,
        ])
    }

    private func faults(of module: DiscoveredModule) async throws -> JSON {
        let address = Self.hex([module.address])
        try await diag.select(module: module.address)
        switch try await diag.readFaults(module.address) {
        case .positive(let payload):
            guard let faults = DTCParse.bmwFaults(payload) else {
                throw ToolFailure("module \(address) answered \(Self.hex(payload)) which is not a fault list")
            }
            return .object([
                "module": .string(address), "name": Self.text(module.name),
                "faults": .array(faults.map { fault in
                    .object(["code": .string(fault.code), "status": .string(Self.hex([fault.status]))])
                }),
            ])
        case .negative(let code): throw ToolFailure("module \(address) refused the fault read (0x\(Self.hex([code])))")
        case .noResponse: throw ToolFailure("module \(address) did not answer the fault read")
        }
    }

    private func standardFaults() async throws -> JSON {
        let stored = Self.codes(try await diag.obd([0x03]))
        let pending = Self.codes(try await diag.obd([0x07]))
        guard !stored.isEmpty || !pending.isEmpty else { throw ToolFailure("no controller answered standard OBD") }
        return .object([
            "stored": .object(stored.mapValues(Self.strings)), "pending": .object(pending.mapValues(Self.strings)),
        ])
    }

    private func identification(of module: DiscoveredModule) -> JSON {
        .object([
            "module": .string(Self.hex([module.address])), "name": Self.text(module.name),
            "identification": .object(module.identification.reduce(into: [:]) {
                $0[Self.identifier($1.key)] = .string(Self.hex($1.value))
            }),
            "codingFiles": Self.strings(module.codingFiles), "hardware": Self.text(module.hardware),
            "software": Self.text(module.software), "serial": Self.text(module.serial),
        ])
    }

    private func codingList(of module: DiscoveredModule) throws -> JSON {
        guard let stored = backedUp(module) else {
            throw ToolFailure("no backup holds module \(Self.hex([module.address])); ask the owner to run Backup")
        }
        return .object([
            "module": .string(Self.hex([module.address])), "source": .string(stored.source),
            "identifiers": .object(stored.coding.mapValues { .number(Double($0.count / 2)) }),
        ])
    }

    /// From the latest backup when it holds `did`, else the same live read as `read_value`.
    private func coding(_ did: UInt16, of module: DiscoveredModule) async throws -> JSON {
        if let stored = backedUp(module), let bytes = stored.coding[Self.identifier(did)] {
            return Self.reading(did, of: module, bytes: bytes, source: stored.source)
        }
        return Self.reading(did, of: module, bytes: try await liveRead(did, of: module), source: "live")
    }

    /// The latest backup's coding of `module`, and `backup <date>` to say where it came from.
    private func backedUp(_ module: DiscoveredModule) -> (coding: [String: String], source: String)? {
        guard let backup = car.latestBackup,
              let entry = backup.modules.first(where: { $0.address == module.address }) else { return nil }
        return (entry.coding, "backup " + backup.date.formatted(.iso8601))
    }

    /// A live `0x22` read of `did` on `module`, its bytes as hex; it counts toward `readValueCap`.
    private func liveRead(_ did: UInt16, of module: DiscoveredModule) async throws -> String {
        guard liveReads < Self.readValueCap else {
            throw ToolFailure("read_value limit of \(Self.readValueCap) per message reached")
        }
        liveReads += 1
        let address = Self.hex([module.address]), identifier = Self.identifier(did)
        try await diag.select(module: module.address)
        switch try await diag.readDID(module.address, did) {
        case .positive(let data): return Self.hex(data)
        case .negative(let code): throw ToolFailure("module \(address) refused \(identifier) (0x\(Self.hex([code])))")
        case .noResponse: throw ToolFailure("module \(address) did not answer \(identifier)")
        }
    }

    private func standardValue(_ pid: UInt8) async throws -> JSON {
        let answers = try await diag.obd([0x01, pid])
        guard !answers.isEmpty else { throw ToolFailure("no controller answered PID \(Self.hex([pid]))") }
        return .object([
            "pid": .string(Self.hex([pid])),
            "answers": .object(answers.reduce(into: [:]) { $0[Self.controller($1.key)] = .string(Self.hex($1.value)) }),
        ])
    }

    /// One module of the health check: what the scan found, and its fault codes or why there are none.
    private func health(of module: DiscoveredModule) async throws -> HealthCheck.ModuleHealth {
        var health = HealthCheck.ModuleHealth(
            address: Self.hex([module.address]), name: module.name, description: module.description,
            signed: module.signed, hardware: module.hardware, software: module.software, serial: module.serial,
            codingFiles: module.codingFiles)
        try await diag.select(module: module.address)
        switch try await diag.readFaults(module.address) {
        case .positive(let payload):
            if let faults = DTCParse.bmwFaults(payload) {
                health.faults = faults.map { .init(code: $0.code, status: Self.hex([$0.status])) }
            } else {
                health.faultRead = "unreadable \(Self.hex(payload))"
            }
        case .negative(let code): health.faultRead = "refused (0x\(Self.hex([code])))"
        case .noResponse: health.faultRead = "no answer"
        }
        return health
    }

    /// Standard OBD-II for the health check: stored and pending codes, then mode 01. PID `00` first, then each
    /// PID the controllers advertise, one request each in ascending order and at most 64 value requests in all;
    /// `20` is read only when a controller advertised it in `00`, `40` only when one advertised it in `20`. `nil`
    /// when modes `03` and `07` and PID `00` all went unanswered.
    private func standardOBD(progress: (String) -> Void) async throws -> HealthCheck.OBDHealth? {
        func request(_ payload: [UInt8]) async throws -> [UInt16: [UInt8]] {
            try Task.checkCancellation()  // between two requests, so no answer is left unread
            return try await diag.obd(payload)
        }
        progress("Reading standard OBD codes …")
        let stored = try await request([0x03]), pending = try await request([0x07])
        progress("Reading standard OBD values …")
        var supported: [String: [String]] = [:], values: [String: [String: String]] = [:]
        var answeredSupport = false, valueRequests = 0
        var base: UInt8? = 0x00
        while let current = base {
            let answers = try await request([0x01, current])
            answeredSupport = answeredSupport || !answers.isEmpty
            var advertised: Set<UInt8> = []
            for (id, answer) in answers {
                guard let pids = DTCParse.supportedPIDs(answer, base: current) else { continue }
                supported[Self.controller(id), default: []] += pids.map { Self.hex([$0]) }
                advertised.formUnion(pids)
            }
            // `20` and `40` are support PIDs: read as the next base when advertised, never as values.
            base = current < 0x40 && advertised.contains(current + 0x20) ? current + 0x20 : nil
            for pid in advertised.sorted() where pid != base && valueRequests < 64 {
                valueRequests += 1
                for (id, answer) in try await request([0x01, pid]) {
                    values[Self.controller(id), default: [:]][Self.hex([pid])] = Self.hex(answer)
                }
            }
        }
        guard !stored.isEmpty || !pending.isEmpty || answeredSupport else { return nil }
        return .init(
            storedCodes: Self.codes(stored), pendingCodes: Self.codes(pending), supportedPIDs: supported,
            values: values)
    }

    private static func reading(
        _ did: UInt16, of module: DiscoveredModule, bytes: String, source: String? = nil
    ) -> JSON {
        var fields: [String: JSON] = [
            "module": .string(hex([module.address])), "did": .string(identifier(did)), "bytes": .string(bytes),
        ]
        if let source { fields["source"] = .string(source) }
        return .object(fields)
    }

    /// Each controller's codes from its answer to mode `03` or `07`, by CAN id; one whose answer does not decode
    /// is left out.
    private static func codes(_ answers: [UInt16: [UInt8]]) -> [String: [String]] {
        answers.reduce(into: [:]) { codes, answer in
            if let list = DTCParse.obdCodes(answer.value) { codes[controller(answer.key)] = list }
        }
    }

    /// A module as the owner sees it named: its table name, or its address as `0x5B`.
    private static func name(of module: DiscoveredModule) -> String {
        module.name ?? "0x" + hex([module.address])
    }

    /// A client tool: strict, its input an object of exactly `properties`, every one of them required.
    private static func tool(_ name: String, _ description: String, _ properties: [(String, JSON)] = []) -> JSON {
        .object([
            "name": .string(name), "description": .string(description), "strict": .bool(true),
            "input_schema": .object([
                "type": .string("object"), "properties": .object(Dictionary(uniqueKeysWithValues: properties)),
                "required": .array(properties.map { .string($0.0) }), "additionalProperties": .bool(false),
            ]),
        ])
    }

    /// A string property, or with `orNull` a string or null.
    private static func property(_ description: String, orNull: Bool = false) -> JSON {
        var schema: [String: JSON] = orNull
            ? ["anyOf": .array([.object(["type": .string("string")]), .object(["type": .string("null")])])]
            : ["type": .string("string")]
        schema["description"] = .string(description)
        return .object(schema)
    }

    /// Bytes as upper-case hex without spaces, as in `0102`; one byte is an address, as `40`.
    private static func hex(_ bytes: [UInt8]) -> String { ISOTP.hexLine(bytes).filter { $0 != " " } }
    /// A data identifier as four hex digits, as `3002`.
    private static func identifier(_ did: UInt16) -> String { String(format: "%04X", did) }
    /// A controller by the CAN id it answered on, as `7E8`.
    private static func controller(_ id: UInt16) -> String { String(format: "%03X", id) }
    private static func text(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
    private static func strings(_ values: [String]) -> JSON { .array(values.map(JSON.string)) }
}

/// Why a tool call has no answer, given to the model as an `is_error` result.
private struct ToolFailure: Error {
    let text: String
    init(_ text: String) { self.text = text }
}
