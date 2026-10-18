import SSE
import Testing

/// Chunk-boundary tests: the result of parsing a stream must not depend on how it is split.
@Suite("Parser chunk boundaries")
struct ParserChunkingTests {
    /// Streams that exercise every construct the parser has state for.
    static let fixtures: [(name: String, bytes: [UInt8])] = [
        ("spec YHOO", Array("data: YHOO\ndata: +2\ndata: 10\n\n".utf8)),
        (
            "spec four blocks",
            Array(": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\n".utf8)
        ),
        ("spec empty data", Array("data\n\ndata\ndata\n\ndata:".utf8)),
        (
            "CRLF everywhere",
            Array("event: a\r\ndata: 1\r\ndata: 2\r\nid: x\r\n\r\ndata: 3\r\n\r\n".utf8)
        ),
        ("CR only", Array("data: 1\rdata: 2\r\rretry: 77\rdata: 3\r\r".utf8)),
        ("mixed terminators", Array("data:a\r\n\ndata:b\r\r\ndata:c\n\r\n".utf8)),
        ("BOM", [0xEF, 0xBB, 0xBF] + Array("data: bom\r\n\r\n".utf8)),
        ("partial BOM", [0xEF, 0xBB] + Array("x\ndata: y\n\n".utf8)),
        ("multi-byte UTF-8", Array("data: \u{00E9}\u{20AC}\u{1F600}\r\nid: \u{4E2D}\r\n\r\n".utf8)),
        ("comments and unknown fields", Array(":c\r\nfoo: bar\r\ndata\r\n\r\n:\r\n".utf8)),
        ("long line", Array(("data: " + String(repeating: "abc", count: 300) + "\n\n").utf8)),
    ]

    @Test("Splitting at any single byte position gives the same result", arguments: fixtures)
    func everySingleSplit(fixture: (name: String, bytes: [UInt8])) {
        let expected = parse(fixture.bytes)
        for split in 0...fixture.bytes.count {
            let result = parse(fixture.bytes, splitAt: [split])
            #expect(result == expected, "\(fixture.name): split at \(split)")
        }
    }

    @Test("Splitting at any two byte positions gives the same result", arguments: fixtures)
    func everyPairOfSplits(fixture: (name: String, bytes: [UInt8])) {
        let expected = parse(fixture.bytes)
        let count = fixture.bytes.count
        var mismatches = 0
        for first in 0...count {
            for second in first...count
            where parse(fixture.bytes, splitAt: [first, second]) != expected {
                mismatches += 1
            }
        }
        #expect(mismatches == 0, "\(fixture.name)")
    }

    @Test("Feeding one byte at a time gives the same result", arguments: fixtures)
    func bytewise(fixture: (name: String, bytes: [UInt8])) {
        #expect(parseBytewise(fixture.bytes) == parse(fixture.bytes), "\(fixture.name)")
    }

    @Test("A CRLF split across chunks is a single line terminator")
    func splitCRLF() {
        var parser = EventStreamParser()
        #expect(parser.parse(Array("data: a\r".utf8)).isEmpty)
        // If the LF were a second terminator, this would dispatch "a" on its own.
        #expect(parser.parse(Array("\ndata: b\r".utf8)).isEmpty)
        #expect(parser.parse(Array("\n\r".utf8)) == [ServerSentEvent(data: "a\nb")])
        #expect(parser.parse(Array("\n".utf8)).isEmpty)
    }

    @Test("A BOM split across three chunks is stripped")
    func splitBOM() {
        var parser = EventStreamParser()
        #expect(parser.parse([0xEF]).isEmpty)
        #expect(parser.parse([0xBB]).isEmpty)
        #expect(parser.parse([0xBF]).isEmpty)
        #expect(parser.parse(Array("data: x\n\n".utf8)) == [ServerSentEvent(data: "x")])
    }

    @Test("Empty chunks change nothing")
    func emptyChunks() {
        var parser = EventStreamParser()
        #expect(parser.parse([UInt8]()).isEmpty)
        _ = parser.parse(Array("data: x\r".utf8))
        #expect(parser.parse([UInt8]()).isEmpty)
        #expect(parser.parse(Array("\n\n".utf8)) == [ServerSentEvent(data: "x")])
    }
}
