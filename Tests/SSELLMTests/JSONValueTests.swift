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
                    "i": .number(42),
                    "d": .number(-1.5),
                    "s": .string("x"),
                    "a": .array([.number(1), .string("y")]),
                    "o": .object(["k": .array([])]),
                ]))
    }

    @Test("Booleans and the numbers 0 and 1 stay distinct")
    func boolsAreNotNumbers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("[true,1,0,false]".utf8))
        #expect(value == .array([.bool(true), .number(1), .number(0), .bool(false)]))
    }

    @Test("Encoding and decoding round-trips")
    func roundTrips() throws {
        let value = JSONValue.object([
            "list": .array([.null, .bool(false), .number(3.25), .string("\u{1F600}")]),
            "nested": .object(["empty": .object([:])]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("Accessors return values of the matching case only")
    func accessors() {
        let value = JSONValue.object(["s": .string("x"), "n": .number(2), "b": .bool(true)])
        #expect(value["s"]?.stringValue == "x")
        #expect(value["n"]?.numberValue == 2)
        #expect(value["b"]?.boolValue == true)
        #expect(value["missing"] == nil)
        #expect(value["s"]?.numberValue == nil)
        #expect(JSONValue.array([])["s"] == nil)
        #expect(JSONValue.null.stringValue == nil)
    }
}
