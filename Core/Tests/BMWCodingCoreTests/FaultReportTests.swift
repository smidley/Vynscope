import Foundation
import Testing
@testable import BMWCodingCore

/// A health check of the given modules and standard OBD, read at `readAt`.
private func report(
    readAt: String = "2026-10-30T12:00:00Z", modules: [HealthCheck.ModuleHealth] = [], obd: HealthCheck.OBDHealth? = nil
) -> HealthCheck {
    HealthCheck(vin: "WBY73AW04RFFAKE19", nickname: "i4", chassis: nil, adapter: .init(model: "", firmware: ""),
                modules: modules, obd: obd, obdError: nil, backup: nil, readAt: readAt)
}

/// A module as the health check records it: its faults when it answered, else why not.
private func module(
    _ address: String, name: String? = nil, faults: [HealthCheck.Fault]? = nil, faultRead: String? = nil
) -> HealthCheck.ModuleHealth {
    .init(address: address, name: name, description: nil, signed: false, hardware: nil, software: nil, serial: nil,
          codingFiles: [], faults: faults, faultRead: faultRead)
}

private func obd(stored: [String: [String]] = [:], pending: [String: [String]] = [:]) -> HealthCheck.OBDHealth {
    .init(storedCodes: stored, pendingCodes: pending, supportedPIDs: [:], values: [:])
}

@Test func chipReadsTheStatusBitsInOrder() {
    #expect(FaultChip.chip(forStatus: "2F") == .active)   // bits 0, 1, 2, 3, 5: test-failed wins
    #expect(FaultChip.chip(forStatus: "04") == .pending)
    #expect(FaultChip.chip(forStatus: "0C") == .pending)  // pending beats confirmed
    #expect(FaultChip.chip(forStatus: "08") == .stored)
    #expect(FaultChip.chip(forStatus: "28") == .stored)
    #expect(FaultChip.chip(forStatus: "20") == .old)
    #expect(FaultChip.chip(forStatus: "00") == .old)
    #expect(FaultChip.chip(forStatus: "zz") == nil)
}

@Test func aReadIsFreshForTenMinutes() throws {
    let now = try Date("2026-10-30T12:10:00Z", strategy: .iso8601)
    #expect(report(readAt: "2026-10-30T12:05:00Z").isFresh(at: now))
    #expect(report(readAt: "2026-10-30T12:00:00Z").isFresh(at: now))        // 600 s exactly
    #expect(!report(readAt: "2026-10-30T11:59:59Z").isFresh(at: now))
    #expect(!report(readAt: "not a date").isFresh(at: now))
    #expect(report(readAt: "2026-10-30T12:05:00Z").isFresh(at: now, maxAge: 60) == false)
}

@Test func theSummaryNamesEveryModuleAndTheOBDCodes() {
    let check = report(
        modules: [
            module("12", name: "DME", faults: [.init(code: "801E2B", status: "2F"), .init(code: "930BD1", status: "04")]),
            module("40", name: "BDC_BODY3", faults: []),
            module("60", faultRead: "no answer"),
        ],
        obd: obd(stored: ["7E8": ["P0A80"]]))
    #expect(check.faultSummary == """
        I just read the fault codes:
        DME (12): 801E2B active, 930BD1 pending
        BDC_BODY3 (40): no faults
        0x60: no answer
        OBD stored: P0A80
        """)
}

@Test func aSummaryWhereNothingAnsweredSaysSo() {
    let check = report(modules: [module("12", name: "DME", faultRead: "no answer"), module("60", faultRead: "no answer")])
    #expect(check.faultSummary == "I just read the fault codes:\nno module answered")
}

// What the summary above does not reach: a status that is not a byte, a refusal, the pending line, and several
// controllers in sorted order with each one's codes as stored.
@Test func theSummaryKeepsWhatItCannotReadAndListsEveryController() {
    let check = report(
        modules: [
            module("12", name: "DME", faults: [.init(code: "801E2B", status: "zz"), .init(code: "930BD1", status: "28")]),
            module("56", name: "FZD__35", faultRead: "refused (0x11)"),
        ],
        obd: obd(stored: ["7EB": ["P0172"], "7EA": ["P0420"], "7E8": ["P0A80", "U0100"], "7E9": ["P0171"]],
                 pending: ["7E9": ["P0300"]]))
    #expect(check.faultSummary == """
        I just read the fault codes:
        DME (12): 801E2B status zz, 930BD1 stored
        FZD__35 (56): refused (0x11)
        OBD stored: P0A80, U0100, P0171, P0420, P0172
        OBD pending: P0300
        """)
}
