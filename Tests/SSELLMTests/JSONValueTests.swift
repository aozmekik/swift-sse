import Foundation
import SSELLM
import Testing

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Every JSON type decodes to its case")
    func decodesAllTypes() throws {
        let json =
            #"{"n":null,"t":true,"f":false,"i":42,"d":-1.5,"s":"x","a":[1,"y"],"o":{"k":[]}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(
            value
                == .object([
                    "n": .null,
                    "t": .bool(true),
                    "f": .bool(false),
                    "i": .integer(42),
                    "d": .number(-1.5),
                    "s": .string("x"),
                    "a": .array([.integer(1), .string("y")]),
                    "o": .object(["k": .array([])]),
                ]))
    }

    @Test("Booleans and the numbers 0 and 1 stay distinct")
    func boolsAreNotNumbers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("[true,1,0,false]".utf8))
        #expect(value == .array([.bool(true), .integer(1), .integer(0), .bool(false)]))
    }

    @Test("Integers in the range of Int64 are exact; other numbers are Doubles")
    func numberPrecision() throws {
        // 12345678901234567890 is beyond Int64, so it becomes the nearest Double,
        // 12345678901234567168.
        let json = """
            [9007199254740993, -9223372036854775808, 9223372036854775807, 1.0, 1e3, 0.5,
            12345678901234567890]
            """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(
            value
                == .array([
                    .integer(9_007_199_254_740_993), .integer(.min), .integer(.max), .integer(1),
                    .integer(1_000), .number(0.5), .number(12_345_678_901_234_567_168),
                ]))
        let encoded = try JSONEncoder().encode(JSONValue.integer(9_007_199_254_740_993))
        #expect(String(decoding: encoded, as: UTF8.self) == "9007199254740993")
    }

    @Test("Encoding and decoding round-trips")
    func roundTrips() throws {
        let value = JSONValue.object([
            "list": .array([
                .null, .bool(false), .integer(-7), .number(3.25), .string("\u{1F600}"),
            ]),
            "nested": .object(["empty": .object([:])]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("Accessors return values of the matching case only")
    func accessors() {
        let value = JSONValue.object([
            "s": .string("x"), "n": .number(2), "f": .number(2.5), "i": .integer(3),
            "b": .bool(true),
        ])
        #expect(value["s"]?.stringValue == "x")
        #expect(value["n"]?.numberValue == 2)
        #expect(value["n"]?.integerValue == 2)
        #expect(value["f"]?.integerValue == nil)
        #expect(value["i"]?.integerValue == 3)
        #expect(value["i"]?.numberValue == 3)
        #expect(value["b"]?.integerValue == nil)
        #expect(value["b"]?.boolValue == true)
        #expect(value["missing"] == nil)
        #expect(value["s"]?.numberValue == nil)
        #expect(JSONValue.array([])["s"] == nil)
        #expect(JSONValue.null.stringValue == nil)
    }
}
