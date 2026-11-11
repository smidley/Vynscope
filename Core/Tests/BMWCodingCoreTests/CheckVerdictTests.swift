import Testing
@testable import BMWCodingCore

private func report(modules: [HealthCheck.ModuleHealth] = [], obd: HealthCheck.OBDHealth? = nil) -> HealthCheck {
    HealthCheck(vin: "WBY73AW04RFFAKE19", nickname: "i4", chassis: nil, adapter: .init(model: "", firmware: ""),
                modules: modules, obd: obd, obdError: nil, backup: nil, readAt: "2026-10-30T12:00:00Z")
}

private func module(
    _ address: String, name: String? = nil, description: String? = nil, faults: [HealthCheck.Fault]? = nil,
    faultRead: String? = nil
) -> HealthCheck.ModuleHealth {
    .init(address: address, name: name, description: description, signed: false, hardware: nil, software: nil,
          serial: nil, codingFiles: [], faults: faults, faultRead: faultRead)
}

private func obd(stored: [String: [String]] = [:], pending: [String: [String]] = [:]) -> HealthCheck.OBDHealth {
    .init(storedCodes: stored, pendingCodes: pending, supportedPIDs: [:], values: [:])
}

@Test func cleanWhenEverySystemWasReadAndNoneHasCodes() {
    let verdict = report(modules: [module("01", faults: []), module("56", faults: [])]).verdict()
    #expect(verdict == CheckVerdict(
        codes: 0, systemsWithCodes: 0, active: 0, read: 2, unread: 0, rows: [], nothingAnswered: false))
    #expect(verdict.clean)
}

@Test func countsCodesSystemsAndActiveOnesWithARowPerSystem() {
    let verdict = report(modules: [
        module("56", name: "FZD__35", description: "Roof functions",
               faults: [.init(code: "E1C441", status: "2F"), .init(code: "E1C442", status: "08")]),
        module("78", name: "IHKA_PRO2",
               faults: [.init(code: "801A2B", status: "28"), .init(code: "801A2C", status: "08")]),
        module("29", faults: [.init(code: "D0170A", status: "20")]),
        module("01", faults: []),
    ]).verdict()
    #expect(verdict.codes == 5 && verdict.systemsWithCodes == 3 && verdict.active == 1)
    #expect(verdict.read == 4 && verdict.unread == 0 && !verdict.clean)
    #expect(verdict.rows == [
        .init(name: "Roof functions", chips: [.active, .stored]),
        .init(name: "IHKA_PRO2", chips: [.stored]),
        .init(name: "System 0x29", chips: [.old]),
    ])
}

@Test func unreadAndSilentSystemsBlockTheGreenVerdict() {
    let check = report(modules: [
        module("01", faults: []), module("56", faultRead: "refused (0x11)"),
        module("60", faultRead: "no answer"), module("63", faultRead: "unreadable 5902"),
    ])
    #expect(check.verdict().unread == 3 && !check.verdict().clean)
    let verdict = check.verdict(silent: 2)
    #expect(verdict.read == 1 && verdict.unread == 5 && verdict.codes == 0 && !verdict.clean)
    #expect(!report(modules: [module("01", faults: [])]).verdict(silent: 1).clean)
}

@Test func standardCodesAddARowAndASystemOnlyWhenTheCarReportedSome() {
    let none = report(modules: [module("01", faults: [])], obd: obd()).verdict()
    #expect(none.codes == 0 && none.systemsWithCodes == 0 && none.rows.isEmpty && none.clean)
    let some = report(
        modules: [module("01", faults: [])],
        obd: obd(stored: ["7E8": ["P0A1F"]], pending: ["7E8": ["P0AA6"], "7E9": ["P1E00"]])).verdict()
    #expect(some.codes == 3 && some.systemsWithCodes == 1 && some.active == 0)
    #expect(some.rows == [.init(name: "Standard codes", chips: [.pending, .stored])])
}

@Test func aFailedStandardReadCountsAsUnread() {
    var check = report(modules: [module("01", faults: [])])
    check.obdError = "timeout"
    #expect(check.verdict().unread == 1 && !check.verdict().clean)
}

@Test func nothingAnsweredIsNeverClean() {
    let verdict = report(modules: [module("01", faultRead: "no answer")]).verdict()
    #expect(verdict.nothingAnswered && !verdict.clean)
}

@Test func aReadOfNoSystemIsNeverClean() {
    let verdict = report(obd: obd()).verdict()
    #expect(verdict.read == 0 && verdict.unread == 0 && verdict.codes == 0 && !verdict.nothingAnswered)
    #expect(!verdict.clean)
}

@Test func standardCodesAndAnUnreadSystemAreBothCounted() {
    let verdict = report(
        modules: [module("01", faults: []), module("56", faultRead: "refused (0x11)")],
        obd: obd(stored: ["7E8": ["P0A1F"]])).verdict()
    #expect(verdict.codes == 1 && verdict.systemsWithCodes == 1 && verdict.read == 1 && verdict.unread == 1)
    #expect(verdict.rows == [.init(name: "Standard codes", chips: [.stored])])
    #expect(!verdict.clean)
}

@Test func silentSystemsAndAReadInWhichNothingAnswered() {
    let verdict = report(modules: [module("01", faultRead: "no answer")]).verdict(silent: 2)
    #expect(verdict.read == 0 && verdict.unread == 3 && verdict.nothingAnswered)
    #expect(!verdict.clean)
}

@Test func aStatusThatIsNotAByteHasNoChipAndStillCounts() {
    let verdict = report(modules: [module("56", faults: [.init(code: "E1C441", status: "zz")])]).verdict()
    #expect(verdict.codes == 1 && verdict.rows == [.init(name: "System 0x56", chips: [])])
}

@Test func problemLinesSayWhatToDo() {
    func line(_ error: any Error, _ connecting: Bool = false) -> String {
        CheckProblem.line(for: error, connecting: connecting)
    }
    #expect(line(LinkError.adapterError("Bluetooth is off. Switch it on and reconnect."))
        == "Bluetooth is off. Switch it on and try again.")
    #expect(line(LinkError.adapterError("Bluetooth is not allowed for this app"))
        == "Vynscope is not allowed to use Bluetooth. Allow it in Settings and try again.")
    #expect(line(LinkError.adapterError("This device does not support Bluetooth LE"))
        == "This device has no Bluetooth LE, which the adapter needs.")
    #expect(line(LinkError.adapterError("CAN ERROR"), true)
        == "No adapter found. Plug it in, wait for its light and try again.")
    #expect(line(LinkError.adapterError("CAN ERROR"), false) == "The adapter reported a problem. Try again.")
    #expect(line(LinkError.timeout) == "The adapter did not answer in time. Try again.")
    #expect(line(LinkError.disconnected) == "The connection to the adapter was lost. Move closer and try again.")
    #expect(line(DiagError.keptDropping) == "The connection to the adapter was lost. Move closer and try again.")
    #expect(line(LinkError.reconnected) == "The adapter reconnected. Try again.")
    #expect(line(VINError.noVIN) == CheckProblem.silentCar)
    #expect(line(DiagError.carSilent) == CheckProblem.silentCar)
    #expect(line(DiagError.differentCar("WBY73AW04RFFAKE19")) == "A different car answered. Check again to read it.")
    #expect(line(DiagError.notAllowed([0x04])) == "The check could not finish. Try again.")
}
