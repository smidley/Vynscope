import Foundation
import Testing
@testable import BMWCodingCore

@Test func vinValidation() {
    #expect(VIN.isValid("WBY73AW04RFFAKE19"))
    #expect(!VIN.isValid("WBY73AW04RFFAKE1"))
    #expect(!VIN.isValid("WBY73AW04RFFAKE1I"))
    #expect(!VIN.isValid("wby73aw04rffake19"))
}
@Test func readsVINFromSecondCandidateWhenFirstIsGarbage() async throws {
    let link = FakeLink { cmd in
        switch cmd {
        case "40 03 22 F1 90 00 00 00": return ["640 F1 05 62 F1 90 41 42 00 00"]
        case "10 03 22 F1 90 00 00 00": return ["610 F1 10 14 62 F1 90 35 55", "610 F1 21 58 57 58 37 43 35", "610 F1 22 58 46 30 4B 30 30", "610 F1 23 30 30 30 00 00 00"]
        default: return cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] } }
    #expect(try await VIN.read(diag: Diag(link: link, log: Log())) == "5UXWX7C5XF0K00000")
}
@Test func noVINThrows() async {
    let link = FakeLink { cmd in cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"] }
    await #expect(throws: VINError.noVIN) { try await VIN.read(diag: Diag(link: link, log: Log())) }
}
@Test func carBookRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cars-\(UUID()).json")
    var book = CarBook.load(from: url)
    #expect(book.cars.isEmpty)
    book.set(nickname: "i4", for: "WBY73AW04RFFAKE19")
    try book.save(to: url)
    #expect(CarBook.load(from: url).car(for: "WBY73AW04RFFAKE19") == CarRecord(vin: "WBY73AW04RFFAKE19", nickname: "i4"))
}

// Edge cases the scenarios above do not pin down.

// A fake adapter: the commands in `answers` get their lines, other adapter commands OK, anything else silence.
private func adapter(_ answers: [String: [String]]) -> FakeLink {
    FakeLink { cmd in answers[cmd] ?? (cmd.hasPrefix("AT") ? ["OK"] : ["NO DATA"]) }
}
// The lines the module answering on CAN id `id` sends to a read of F190 that it answers with the 17 bytes of
// `vin`: a first frame and three consecutive frames.
private func f190Answer(_ id: String, _ vin: [UInt8]) -> [String] {
    func hex(_ part: Range<Int>) -> String { vin[part].map { String(format: "%02X", $0) }.joined(separator: " ") }
    return ["\(id) F1 10 14 62 F1 90 \(hex(0..<2))", "\(id) F1 21 \(hex(2..<8))", "\(id) F1 22 \(hex(8..<14))",
            "\(id) F1 23 \(hex(14..<17)) 00 00 00"]
}
// What VIN.read sends to try the module at `address`: select it, then read F190.
private func ask(_ address: String) -> [String] {
    ["ATCRA 6\(address)", "ATFCSD \(address) 30 00 00", "\(address) 03 22 F1 90 00 00 00"]
}
private let i4VIN = Array("WBY73AW04RFFAKE19".utf8)

@Test func theVINAlphabetIsAToHJToNPRToZAndTheDigits() {
    let valid = Set("ABCDEFGH" + "JKLMN" + "P" + "RSTUVWXYZ" + "0123456789")
    for code in UInt8(0)...127 {
        let c = Character(Unicode.Scalar(code))
        var vin = Array("WBY73AW04RFFAKE19")
        vin[Int(code) % 17] = c  // every position gets its share of the characters
        #expect(VIN.isValid(String(vin)) == valid.contains(c), "character code \(code)")
    }
}
@Test func aVINIsExactlySeventeenASCIICharacters() {
    #expect(!VIN.isValid(""))
    #expect(!VIN.isValid("WBY73AW04RFFAKE199"))  // 18 characters
    #expect(!VIN.isValid("WBY73AW04RFFAKE1９"))  // 17 characters, the last a full-width 9
}

@Test func readSelectsTheModuleThenReadsF190AndStopsAtTheFirstVIN() async throws {
    let link = adapter(["40 03 22 F1 90 00 00 00": f190Answer("640", i4VIN)])
    #expect(try await VIN.read(diag: Diag(link: link, log: Log())) == "WBY73AW04RFFAKE19")
    #expect(link.sent == ask("40"))
}
@Test func readAsksTheCandidatesInOrderSkippingRefusalSilenceAndABadCharacter() async throws {
    let link = adapter([
        "40 03 22 F1 90 00 00 00": ["640 F1 03 7F 22 31 00 00 00"],  // refuses
        // 10 stays silent
        "60 03 22 F1 90 00 00 00": f190Answer("660", Array("WBY73AW04RFFAKE1I".utf8)),  // 17 bytes, but an I
        "63 03 22 F1 90 00 00 00": f190Answer("663", i4VIN)])
    #expect(try await VIN.read(diag: Diag(link: link, log: Log())) == "WBY73AW04RFFAKE19")
    #expect(link.sent == ask("40") + ask("10") + ask("60") + ask("63"))
}
@Test func readSkipsAnAnswerThatIsNotUTF8() async throws {
    let link = adapter(["40 03 22 F1 90 00 00 00": f190Answer("640", Array("WBY73AW04RFFAKE1".utf8) + [0xFF]),
                        "10 03 22 F1 90 00 00 00": f190Answer("610", i4VIN)])
    #expect(try await VIN.read(diag: Diag(link: link, log: Log())) == "WBY73AW04RFFAKE19")
    #expect(link.sent == ask("40") + ask("10"))
}
@Test func readLetsAdapterAndLinkFailuresThrowInsteadOfMovingOn() async {
    let bus = FakeLink { cmd in cmd.hasPrefix("40 03") ? ["CAN ERROR"] : ["OK"] }
    await #expect(throws: LinkError.adapterError("CAN ERROR")) {
        try await VIN.read(diag: Diag(link: bus, log: Log()))
    }
    #expect(!bus.sent.contains { $0.hasPrefix("ATCRA 610") })  // the next candidate was not tried
    let dead = FakeLink { _ in throw LinkError.disconnected }
    await #expect(throws: LinkError.disconnected) { try await VIN.read(diag: Diag(link: dead, log: Log())) }
}

@Test func setReplacesTheNicknameOfAKnownCarAndAddsAnUnknownOne() {
    var book = CarBook(cars: [CarRecord(vin: "WBY73AW04RFFAKE19", nickname: "i4"),
                              CarRecord(vin: "5UXWX7C5XF0K00000", nickname: "X3")])
    book.set(nickname: "Blue i4", for: "WBY73AW04RFFAKE19")
    #expect(book.cars.map(\.nickname) == ["Blue i4", "X3"])  // replaced in place, nothing added
    book.set(nickname: "Spare", for: "WBAJA7C50GG000001")
    #expect(book.cars.count == 3)
    #expect(book.car(for: "WBAJA7C50GG000001") == CarRecord(vin: "WBAJA7C50GG000001", nickname: "Spare"))
    #expect(book.car(for: "5UXWX7C5XF0K00000")?.nickname == "X3")
    #expect(book.car(for: "5UXWX7C5XF0K00001") == nil)
}
@Test func aFileThatCannotBeDecodedLoadsAsEmpty() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cars-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    for text in ["", "not json", "[]", "{\"cars\": 5}"] {
        try Data(text.utf8).write(to: url)
        #expect(CarBook.load(from: url).cars.isEmpty, "\(text)")
    }
}
@Test func theFileHoldsPrettyPrintedJSONWithSortedKeys() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cars-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let json = """
        {
          "cars" : [
            {
              "nickname" : "i4",
              "vin" : "WBY73AW04RFFAKE19"
            },
            {
              "nickname" : "X3",
              "vin" : "5UXWX7C5XF0K00000"
            }
          ]
        }
        """
    try Data(json.utf8).write(to: url)
    let book = CarBook.load(from: url)
    #expect(book.cars == [CarRecord(vin: "WBY73AW04RFFAKE19", nickname: "i4"),
                          CarRecord(vin: "5UXWX7C5XF0K00000", nickname: "X3")])
    try book.save(to: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == json)
}
@Test func saveCreatesMissingFoldersAndReplacesAnExistingFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cars-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("a/b/cars.json")
    var book = CarBook(cars: [])
    book.set(nickname: "i4", for: "WBY73AW04RFFAKE19")
    try book.save(to: url)
    book.set(nickname: "X3", for: "5UXWX7C5XF0K00000")
    try book.save(to: url)
    #expect(CarBook.load(from: url) == book)
}
