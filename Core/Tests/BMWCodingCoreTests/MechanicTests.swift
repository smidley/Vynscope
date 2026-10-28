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
