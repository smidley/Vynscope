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
    /// not answer, and a read over the cap all answer with `isError`; only what `Diag` throws (`LinkError`, a
    /// cancel) is thrown.
    public func run(_ call: ToolCall) async throws -> ToolResult {
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
