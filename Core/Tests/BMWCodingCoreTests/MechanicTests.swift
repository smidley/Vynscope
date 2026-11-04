import Foundation
import Testing
@testable import BMWCodingCore

/// The i4 with a crash-safety module (identification empty), the body controller (an installed-software table with
/// one coding file, a serial padded with blanks, signed) and the roof module.
func testCar(backup: Backup? = nil) -> MechanicCar {
    func module(_ address: UInt8, signed: Bool = false, identification: [UInt16: [UInt8]] = [:],
                codingFiles: [String] = []) -> DiscoveredModule {
        let info = ModuleTable.info(for: address)
        return DiscoveredModule(
            address: address, name: info?.name, description: info?.description, signed: signed,
            identification: identification, codingFiles: codingFiles, hardware: nil, software: nil,
            answeredIdentification: true)
    }
    return MechanicCar(
        vin: "WBY73AW04RFFAKE19", nickname: "i4",
        adapter: AdapterInfo(model: "OBDLink CX r1.0", firmware: "STN2255 v5.6.2", elmVersion: "ELM327 v1.4b"),
        modules: [
            module(0x01),
            module(0x40, signed: true,
                   identification: [0xF101: [0x00, 0x01, 0x05, 0x00, 0x00, 0x06, 0xC9, 0x18, 0x02, 0x0D],
                                    0xF18C: Array("  SN123  ".utf8)],
                   codingFiles: ["CAFD_000006C9_024_002_013"]),
            module(0x56),
        ],
        latestBackup: backup)
}

/// A backup of module 0x01 alone, two coding identifiers, dated 2026-10-26T21:03:00Z.
func testBackup() -> Backup {
    let module = ModuleBackup(
        address: 0x01, name: "ACSM_5", signed: false, identification: .init(), codingFiles: [],
        coding: ["3000": "0102", "3002": "AABBCCDDEEFF00112233445566"], method: .fullSweep, status: .complete)
    return Backup(
        vin: "WBY73AW04RFFAKE19", nickname: "i4", date: try! Date("2026-10-26T21:03:00Z", strategy: .iso8601),
        appVersion: "0.1", adapter: .init(model: "OBDLink CX r1.0", firmware: "STN2255 v5.6.2"), modules: [module])
}

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
    let silent = FakeLink { cmd in cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] }  // the adapter switches, no car answers
    let none = Mechanic(diag: Diag(link: silent, log: Log()), car: testCar(), log: Log())
    #expect(try await none.run(ToolCall(id: "t", name: "read_faults", input: .object(["module": .string("obd")]))).isError)
}
@Test func readIdentificationReadsNothing() async throws {
    let link = FakeLink { _ in ["OK"] }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    let result = try await mechanic.run(ToolCall(id: "t", name: "read_identification", input: .object(["module": .string("40")])))
    let json = try JSON.parse(Data(result.content.utf8))
    #expect(json["serial"]?.string == "SN123" && json["codingFiles"]?.array?.count == 1)
    #expect(json["identification"]?["F18C"]?.string == "2020534E3132332020")  // "  SN123  " as hex
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

// What the scenarios above do not pin down.

@Test func readOBDKeysEachWholeAnswerByController() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "01 42": return ["7E8 04 41 42 30 B2"]
        case "01 0D": return ["NO DATA"]
        default: return ["OK"] } }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    let result = try await mechanic.run(ToolCall(id: "t", name: "read_obd", input: .object(["pid": .string("42")])))
    #expect(result.content == #"{"answers":{"7E8":"414230B2"},"pid":"42"}"#)
    #expect(try await mechanic.run(ToolCall(id: "t", name: "read_obd", input: .object(["pid": .string("0d")])))
        == ToolResult("no controller answered PID 0D", isError: true))
}
@Test func everyCallIsLoggedWithItsResult() async throws {
    let log = Log()
    let mechanic = Mechanic(diag: Diag(link: FakeLink { _ in ["OK"] }, log: Log()), car: testCar(backup: testBackup()), log: log)
    _ = try await mechanic.run(ToolCall(id: "t", name: "get_vehicle", input: .object([:])))
    _ = try await mechanic.run(ToolCall(id: "t", name: "read_faults", input: .object(["module": .string("5B")])))
    let notes = log.entries.map(\.text)
    #expect(notes.count == 4 && notes[0] == "ai: tool get_vehicle {}")
    #expect(notes[1].hasPrefix(#"ai: tool get_vehicle → {"adapter""#) && notes[1].count == "ai: tool get_vehicle → ".count + 120)
    #expect(notes[2] == #"ai: tool read_faults {"module":"5B"}"#)
    #expect(notes[3] == "ai: tool read_faults → error: no module at address 5B on this car")
}
@Test func activityLinesForAnUnnamedModuleAFailedListAndABadInput() {
    var car = testCar()
    car.modules.append(DiscoveredModule(address: 0x5B, name: nil, description: nil, signed: false, identification: [:],
                                        codingFiles: [], hardware: nil, software: nil, answeredIdentification: false))
    func line(_ name: String, _ input: [String: JSON], _ result: ToolResult) -> String {
        Mechanic.activityLine(for: ToolCall(id: "t", name: name, input: .object(input)), result: result, car: car)
    }
    let oneFault = ToolResult(#"{"faults":[{"code":"801E2B","status":"2F"}],"module":"5B","name":null}"#)
    #expect(line("read_faults", ["module": .string("5B")], oneFault) == "Read 1 fault code from 0x5B")
    let noBackup = ToolResult("no backup holds module 01; ask the owner to run Backup", isError: true)
    #expect(line("read_coding", ["module": .string("01"), "did": .null], noBackup)
        == "Could not list ACSM_5's coding identifiers from the backup")
    let notOnTheCar = ToolResult("no module at address 3D on this car", isError: true)
    #expect(line("read_value", ["module": .string("3D"), "did": .string("3000")], notOnTheCar)
        == "Asked for something the app could not read")
}

// The health check, the car context and the system prompt.

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
    #expect(steps == ["Reading fault codes · 1 of 3 · ACSM_5", "Reading fault codes · 2 of 3 · BDC_BODY3", "Reading fault codes · 3 of 3 · FZD__35", "Reading standard OBD codes …", "Reading standard OBD values …"])
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

// What the health check scenarios above do not pin down.

@Test(arguments: ["40 03 19 02 FF 00 00 00", "03"])
func healthCheckStopsAtTheNextRequestAfterACancel(command: String) async throws {
    let link = FakeLink { cmd in
        if cmd == command { withUnsafeCurrentTask { $0?.cancel() } }  // Stop pressed while this request runs
        return ["OK"] }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    let check = Task { try await mechanic.healthCheck { _ in } }
    await #expect(throws: CancellationError.self) { try await check.value }
    #expect(link.sent.last == command)  // the request in flight finished; nothing was sent after it
}
@Test func healthCheckFollowsTheSupportPIDsUpToSixtyFourValues() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "03": return ["7E8 01 43", "7E9 02 43 00"]  // 7E8's answer is cut short: left out, not "no codes"
        case "01 00": return ["7E8 06 41 00 FF FF FF FF", "7E9 06 41 00 80 00 00 00"]
        case "01 20": return ["7E8 06 41 20 FF FF FF FF"]
        case "01 40": return ["7E8 06 41 40 FF FF FF FF"]
        case _ where cmd.hasPrefix("01 ") && cmd.count == 5: return ["7E8 03 41 \(cmd.suffix(2)) 00"]
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] } }
    let check = try await Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log()).healthCheck { _ in }
    let obd = try #require(check.obd)
    #expect(obd.storedCodes == ["7E9": []] && obd.pendingCodes == [:])
    let mode01 = link.sent.filter { $0.hasPrefix("01 ") && $0.count == 5 }
    #expect(mode01.count == 3 + 64 && mode01 == mode01.sorted() && Set(mode01).count == mode01.count)
    #expect(mode01.last == "01 42")  // 31 values below 20, 31 below 40, then 41 and 42
    #expect(obd.values["7E8"]?.count == 64 && obd.values["7E8"]?["20"] == nil && obd.values["7E8"]?["40"] == nil)
    #expect(obd.values["7E8"]?["1F"] == "411F00" && obd.values["7E9"] == nil)
    #expect(obd.supportedPIDs["7E9"] == ["01"] && obd.supportedPIDs["7E8"]?.count == 96)
}
@Test func standardOBDIsKeptWhenOnlyPIDZeroAnswers() async throws {
    let link = FakeLink { cmd in cmd == "01 00" ? ["7E8 06 41 00 00 00 00 00"] : cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] }
    let check = try await Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log()).healthCheck { _ in }
    #expect(check.obd == HealthCheck.OBDHealth(storedCodes: [:], pendingCodes: [:], supportedPIDs: ["7E8": []], values: [:]))
}
@Test func aCancelledToolCallSendsNothing() async throws {
    let link = FakeLink { _ in ["OK"] }
    let mechanic = Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log())
    let call = Task { try await mechanic.run(ToolCall(id: "t", name: "read_faults", input: .object(["module": .string("40")]))) }
    call.cancel()  // Stop pressed between two tool calls of one round
    await #expect(throws: CancellationError.self) { try await call.value }
    #expect(link.sent.isEmpty)
}
@Test func aLinkErrorInTheStandardOBDPartKeepsTheModules() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "40 03 19 02 FF 00 00 00": return ["640 F1 07 59 02 FF 80 1E 2B 2F"]
        case "03": return ["CAN ERROR"]
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] } }
    let check = try await Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log()).healthCheck { _ in }
    #expect(check.modules.map(\.address) == ["01", "40", "56"])
    #expect(check.modules[1].faults == [HealthCheck.Fault(code: "801E2B", status: "2F")])
    #expect(check.obd == nil && check.obdError == "CAN ERROR")
    #expect(check.contextJSON.contains(#""obdError" : "CAN ERROR""#))
    #expect(link.sent.last == "03")  // the check ended there
}
@Test func aGiveUpInTheStandardOBDPartEndsTheCheck() async throws {
    let link = FakeLink { cmd in
        if cmd == "03" { throw LinkError.disconnected }  // the link gave up
        return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] }
    await #expect(throws: LinkError.disconnected) {
        try await Mechanic(diag: Diag(link: link, log: Log()), car: testCar(), log: Log()).healthCheck { _ in }
    }
}

// The provider seam.

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

// What the brief's tests above do not isolate.

@Test func onlyTheWebLineDiffersBetweenTheTwoPrompts() {
    func lines(_ web: Mechanic.WebTools) -> [Substring] {
        (Mechanic.systemPrompt(carContext: "{}", web: web)[0]["text"]?.string ?? "").split(separator: "\n", omittingEmptySubsequences: false)
    }
    #expect(lines(.searchAndFetch).count == lines(.search).count)
    let differing = zip(lines(.searchAndFetch), lines(.search)).filter { $0 != $1 }
    #expect(differing.map(\.0) == ["- web_search and web_fetch: use them to look up what a code means, known faults and service notes for this car."])
    #expect(differing.map(\.1) == ["- web_search: use it to look up what a code means, known faults and service notes for this car."])
}

@Test func eachProviderReadsOnlyItsOwnOwnerMessages() {
    let claude = Mechanic.ownerMessage("hi", provider: .anthropic)
    let gpt = Mechanic.ownerMessage("hi", provider: .openai)
    #expect(!Mechanic.isOwnerMessage(claude, provider: .openai) && !Mechanic.isOwnerMessage(gpt, provider: .anthropic))
    // The Responses API takes `content` as plain text too, and the type of a message may be left out; the owner's
    // is a user's message of that type, and the mechanic's own never is.
    #expect(Mechanic.isOwnerMessage(.object(["role": .string("user"), "content": .string("hi")]), provider: .openai))
    #expect(!Mechanic.isOwnerMessage(.object(["type": .string("message"), "role": .string("assistant"), "content": .string("hi")]), provider: .openai))
    #expect(!Mechanic.isOwnerMessage(.object(["type": .string("custom"), "role": .string("user"), "content": .string("hi")]), provider: .openai))
    let reply = JSON.object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("hi")])])])
    #expect(!Mechanic.isOwnerMessage(reply, provider: .anthropic))
}

@Test func aCheckWhereNothingAnsweredSaysSo() {
    let adapter = HealthCheck.Adapter(model: "OBDLink CX", firmware: "5.6")
    func module(_ address: String, faults: [HealthCheck.Fault]?, faultRead: String?) -> HealthCheck.ModuleHealth {
        .init(address: address, name: nil, description: nil, signed: false, hardware: nil, software: nil, serial: nil,
              codingFiles: [], faults: faults, faultRead: faultRead)
    }
    var check = HealthCheck(vin: "WBY73AW04RFFAKE19", nickname: "i4", chassis: nil, adapter: adapter,
                            modules: [module("40", faults: nil, faultRead: "no answer"), module("10", faults: nil, faultRead: "no answer")],
                            obd: nil, obdError: nil, backup: nil, readAt: "2026-10-29T18:54:00Z")
    #expect(check.nothingAnswered)
    check.modules[0] = module("40", faults: [], faultRead: nil)  // one module answered, with no faults
    #expect(!check.nothingAnswered)
    check.modules[0] = module("40", faults: nil, faultRead: "refused (0x11)")  // a refusal is an answer
    #expect(!check.nothingAnswered)
    check.modules[0] = module("40", faults: nil, faultRead: "no answer")
    check.obd = HealthCheck.OBDHealth(storedCodes: ["7E8": ["P0A80"]], pendingCodes: [:], supportedPIDs: [:], values: [:])
    #expect(!check.nothingAnswered)
}
