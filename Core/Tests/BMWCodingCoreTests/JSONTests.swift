import Foundation
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
@Test func jsonNumbersWriteWithoutNoiseAndNonFiniteOnesAsNull() throws {
    let numbers = JSON.array([.number(-3), .number(2.5), .number(9007199254740991), .number(.nan), .number(.infinity)])
    #expect(String(decoding: numbers.encoded(), as: UTF8.self) == "[-3,2.5,9007199254740991,null,null]")
    #expect(JSON.number(12).int == 12 && JSON.number(12.5).int == nil)
    #expect(try JSON.parse(JSON.number(-9223372036854775808).encoded()) == .number(-9223372036854775808))  // Int.min
}
