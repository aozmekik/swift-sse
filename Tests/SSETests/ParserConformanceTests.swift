import SSE
import Testing

/// Conformance tests for `EventStreamParser`.
///
/// "Spec" tests use the examples of the WHATWG HTML Living Standard, section 9.2.6. "WPT" tests
/// reproduce the streams and expectations of the web-platform-tests `eventsource/format-*` files,
/// which browsers run against their `EventSource` implementations.
@Suite("Parser conformance")
struct ParserConformanceTests {
    // MARK: Examples from the standard

    @Test("Spec: multi-line data is joined with LF")
    func specMultilineData() {
        let result = parse("data: YHOO\ndata: +2\ndata: 10\n\n")
        #expect(result.events == [ServerSentEvent(data: "YHOO\n+2\n10")])
    }

    @Test("Spec: comments, ids and a block that needs a final blank line")
    func specFourBlocks() {
        let stream =
            ": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\n"
            + "data:  third event\n"

        let unterminated = parse(stream)
        #expect(
            unterminated.events == [
                ServerSentEvent(data: "first event", lastEventID: "1"),
                ServerSentEvent(data: "second event", lastEventID: ""),
            ])

        let terminated = parse(stream + "\n")
        #expect(terminated.events.last == ServerSentEvent(data: " third event", lastEventID: ""))
        #expect(terminated.events.count == 3)
    }

    @Test("Spec: empty data fields")
    func specEmptyData() {
        let result = parse("data\n\ndata\ndata\n\ndata:")
        #expect(dataOf(result) == ["", "\n"])
    }

    @Test("Spec: one optional space after the colon is removed")
    func specOptionalSpace() {
        let result = parse("data:test\n\ndata: test\n\n")
        #expect(dataOf(result) == ["test", "test"])
    }

    // MARK: web-platform-tests eventsource/format-*

    @Test("WPT format-bom: a leading BOM is stripped, a later one is not")
    func wptBOM() {
        let result = parse("\u{FEFF}data:1\n\n\u{FEFF}data:2\n\ndata:3\n\n")
        #expect(dataOf(result) == ["1", "3"])
    }

    @Test("WPT format-bom-2: only one leading BOM is stripped")
    func wptDoubleBOM() {
        let result = parse("\u{FEFF}\u{FEFF}data:1\n\ndata:2\n\ndata:3\n\n")
        #expect(dataOf(result) == ["2", "3"])
    }

    @Test("WPT format-comments: comments with every line ending")
    func wptComments() {
        let long = String(repeating: "x", count: 2 * 1024)
        let stream =
            "data:1\r:\0\n:\r\ndata:2\n:" + long + "\rdata:3\n:data:fail\r:" + long
            + "\ndata:4\n\n"
        #expect(dataOf(parse(stream)) == ["1\n2\n3\n4"])
    }

    @Test("WPT format-data-before-final-empty-line: an unterminated block changes nothing")
    func wptDataBeforeFinalEmptyLine() {
        let result = parse("retry:1000\ndata:test1\n\nid:test\ndata:test2")
        #expect(result.events == [ServerSentEvent(data: "test1", lastEventID: "")])
        #expect(result.lastEventID == "")
        #expect(result.reconnectionTime == .milliseconds(1000))
    }

    @Test("WPT format-field-data: data with and without a colon")
    func wptFieldData() {
        let result = parse("data:\n\ndata\ndata\n\ndata:test\n\n")
        #expect(dataOf(result) == ["", "\n", "test"])
    }

    @Test("WPT format-field-event-empty: an empty event type means \"message\"")
    func wptEmptyEventType() {
        let result = parse("event: \ndata:data\n\n")
        #expect(result.events == [ServerSentEvent(type: "message", data: "data")])
    }

    @Test("WPT format-field-event: the event type applies to one block only")
    func wptEventType() {
        let result = parse("event:test\ndata:x\n\ndata:x\n\n")
        #expect(result.events.map(\.type) == ["test", "message"])
    }

    @Test("WPT format-field-id-3: the last event ID persists across events")
    func wptIDPersists() {
        let result = parse("id: 1\ndata: 1\n\ndata: 2\n\nid: 2\ndata:3\n\ndata:4\n\n")
        #expect(result.events.map(\.lastEventID) == ["1", "1", "2", "2"])
    }

    @Test(
        "WPT format-field-id-3: an empty id field resets the last event ID",
        arguments: ["id:\n", "id\n"]
    )
    func wptIDResets(resetLine: String) {
        let result = parse("id: 1\ndata: 1\n\n" + resetLine + "data:2\n\ndata:3\n\n")
        #expect(result.events.map(\.lastEventID) == ["1", "", ""])
        #expect(result.lastEventID == "")
    }

    @Test(
        "WPT format-field-id-null: ids containing NULL are ignored",
        arguments: ["\0\0", "x\0", "\0x", "x\0x", " \0"]
    )
    func wptIDWithNull(id: String) {
        let result = parse("id: " + id + "\nretry: 200\ndata: hello\n\n")
        #expect(result.events == [ServerSentEvent(data: "hello", lastEventID: "")])
        #expect(result.lastEventID == "")
    }

    @Test("WPT format-field-parsing: field names are exact and case-sensitive")
    func wptFieldParsing() {
        let stream =
            "data:\0\ndata:  2\rData:1\ndata\0:2\ndata:1\r\0data:4\nda-ta:3\rdata_5\n"
            + "data:3\rdata:\r\n data:32\ndata:4\n\n"
        #expect(dataOf(parse(stream)) == ["\0\n 2\n1\n3\n\n4"])
    }

    @Test("WPT format-field-retry-bogus: a non-numeric retry is ignored")
    func wptBogusRetry() {
        let result = parse("retry:3000\nretry:1000x\ndata:x\n\n")
        #expect(result.reconnectionTime == .milliseconds(3000))
    }

    @Test("WPT format-field-retry-empty: an empty retry is ignored")
    func wptEmptyRetry() {
        let result = parse("retry\ndata:test\n\n")
        #expect(dataOf(result) == ["test"])
        #expect(result.reconnectionTime == nil)
    }

    @Test("WPT format-field-unknown: unknown fields and lines without a colon")
    func wptUnknownFields() {
        let stream =
            "data:test\n data\ndata\nfoobar:xxx\njustsometext\n:thisisacommentyay\n"
            + "data:test\n\n"
        #expect(dataOf(parse(stream)) == ["test\n\ntest"])
    }

    @Test("WPT format-leading-space: only a space is removed, not a tab")
    func wptLeadingSpace() {
        #expect(dataOf(parse("data:\ttest\rdata: \ndata:test\n\n")) == ["\ttest\n\ntest"])
    }

    @Test("WPT format-newlines: CRLF, LF and CR in one stream")
    func wptNewlines() {
        #expect(dataOf(parse("data:test\r\ndata\ndata:test\r\n\r\n")) == ["test\n\ntest"])
    }

    @Test("WPT format-null-character: NULL in data is kept")
    func wptNullInData() {
        #expect(dataOf(parse("data:\0\n\n")) == ["\0"])
    }

    @Test("WPT format-utf-8: UTF-8 data is decoded")
    func wptUTF8() {
        #expect(dataOf(parse("data:ok\u{20AC}\u{1F600}\n\n")) == ["ok\u{20AC}\u{1F600}"])
    }

    // MARK: Fields

    @Test(
        "retry: only ASCII digits are accepted",
        arguments: [
            ("retry: 1000", Duration?.some(.milliseconds(1000))),
            ("retry:0", .some(.zero)),
            ("retry: 007", .some(.milliseconds(7))),
            ("retry:  1000", nil),
            ("retry: 1e3", nil),
            ("retry: -1", nil),
            ("retry: +1", nil),
            ("retry: 1.5", nil),
            ("retry: 10 ", nil),
            ("retry: \u{0661}", nil),
            ("Retry: 1000", nil),
        ]
    )
    func retryParsing(line: String, expected: Duration?) {
        #expect(parse(line + "\n").reconnectionTime == expected)
    }

    @Test("retry: values beyond Int64 milliseconds saturate")
    func retrySaturates() {
        let result = parse("retry: 99999999999999999999999999\n")
        #expect(result.reconnectionTime == .milliseconds(Int64.max))
    }

    @Test("retry: takes effect immediately, without a dispatch")
    func retryWithoutDispatch() {
        var parser = EventStreamParser()
        _ = parser.parse(Array("retry: 250\n".utf8))
        #expect(parser.reconnectionTime == .milliseconds(250))
        _ = parser.parse(Array("retry: 500\ndata".utf8))
        #expect(parser.reconnectionTime == .milliseconds(500))
    }

    @Test("A block with an id but no data updates the last event ID without an event")
    func idOnlyBlock() {
        let result = parse("id: 5\n\ndata: x\n\n")
        #expect(result.events == [ServerSentEvent(data: "x", lastEventID: "5")])
    }

    @Test("A block without data discards its event type")
    func eventTypeWithoutData() {
        let result = parse("event: ping\n\ndata: x\n\n")
        #expect(result.events == [ServerSentEvent(type: "message", data: "x")])
    }

    @Test("The last event field of a block wins")
    func lastEventFieldWins() {
        let result = parse("event: a\nevent: b\ndata: x\n\n")
        #expect(result.events.map(\.type) == ["b"])
    }

    @Test("A colon inside the value is kept")
    func colonInValue() {
        let result = parse("data: {\"a\":1}\ndata:: x\n\n")
        #expect(dataOf(result) == ["{\"a\":1}\n: x"])
    }

    @Test("Empty lines without data dispatch nothing")
    func emptyLines() {
        #expect(parse("\n\n\r\n\r\r\n\n").events.isEmpty)
    }

    @Test("A CR followed by LF across lines is one terminator, LF CR is two")
    func lineTerminatorPairs() {
        #expect(dataOf(parse("data:a\rdata:b\r\r")) == ["a\nb"])
        #expect(dataOf(parse("data:a\n\rdata:b\n\n")) == ["a", "b"])
    }

    @Test("A stream that ends without a terminator dispatches nothing pending")
    func unterminatedStream() {
        #expect(parse("data: x").events.isEmpty)
        #expect(parse("data: x\n").events.isEmpty)
        #expect(parse("data: x\r").events.isEmpty)
    }

    // MARK: UTF-8

    @Test(
        "Invalid UTF-8 is replaced like the Encoding standard's UTF-8 decoder",
        arguments: [
            ([0xFF], "\u{FFFD}"),
            ([0xF0, 0x9F, 0x98], "\u{FFFD}"),
            ([0xF0, 0x9F, 0x98, 0x41], "\u{FFFD}A"),
            ([0xC0, 0x80], "\u{FFFD}\u{FFFD}"),
            ([0xED, 0xA0, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}"),
            ([0xF4, 0x90, 0x80, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"),
        ] as [([UInt8], String)]
    )
    func invalidUTF8(bytes: [UInt8], expected: String) {
        let stream = Array("data: ".utf8) + bytes + Array("\n\n".utf8)
        #expect(dataOf(parse(stream)) == [expected])
    }

    @Test("A truncated sequence at the end of a line does not swallow the terminator")
    func truncatedSequenceBeforeTerminator() {
        let stream = Array("data: ".utf8) + [0xE2, 0x82] + Array("\ndata: b\n\n".utf8)
        #expect(dataOf(parse(stream)) == ["\u{FFFD}\nb"])
    }

    @Test("An invalid id is decoded with replacement, not rejected")
    func invalidUTF8InID() {
        let stream = Array("id: ".utf8) + [0xFF] + Array("\ndata: x\n\n".utf8)
        #expect(parse(stream).lastEventID == "\u{FFFD}")
    }

    // MARK: Byte order mark

    @Test("A partial BOM followed by other bytes is content")
    func partialBOM() {
        let stream: [UInt8] = [0xEF, 0xBB] + Array("data: x\n\ndata: y\n\n".utf8)
        // The first line's field name is "\u{FFFD}data", an unknown field.
        #expect(dataOf(parse(stream)) == ["y"])
        #expect(dataOf(parse(stream, splitAt: [1])) == ["y"])
    }

    @Test("A stream that is only a BOM produces nothing")
    func onlyBOM() {
        #expect(parse([0xEF, 0xBB, 0xBF]).events.isEmpty)
    }

    // MARK: Parser lifecycle

    @Test("finish() discards the pending block and allows a new stream")
    func finishStartsANewStream() {
        var parser = EventStreamParser()
        #expect(parser.parse(Array("data: stale\nid: 9\nevent: e\n".utf8)).isEmpty)
        parser.finish()
        let events = parser.parse(Array("\u{FEFF}data: fresh\n\n".utf8))
        #expect(events == [ServerSentEvent(data: "fresh")])
        #expect(parser.lastEventID == "")
    }

    @Test("finish() keeps the last event ID and the reconnection time")
    func finishKeepsStreamState() {
        var parser = EventStreamParser()
        _ = parser.parse(Array("retry: 10\nid: 1\ndata: a\n\n".utf8))
        parser.finish()
        let events = parser.parse(Array("data: b\n\n".utf8))
        #expect(events == [ServerSentEvent(data: "b", lastEventID: "1")])
        #expect(parser.reconnectionTime == .milliseconds(10))
    }

    @Test("A CR at the end of a stream does not swallow an LF that starts the next stream")
    func finishResetsPendingCR() {
        var parser = EventStreamParser()
        _ = parser.parse(Array("data: a\r".utf8))
        parser.finish()
        let events = parser.parse(Array("\ndata: b\n\n".utf8))
        #expect(events == [ServerSentEvent(data: "b")])
    }

    @Test("init(lastEventID:) seeds the last event ID, which an empty id resets")
    func initialLastEventID() {
        let result = parse("data: a\n\nid\ndata: b\n\n", lastEventID: "42")
        #expect(result.events.map(\.lastEventID) == ["42", ""])
    }

    @Test("Bytes from a non-contiguous sequence are parsed")
    func nonContiguousInput() {
        var parser = EventStreamParser()
        let bytes = Array("data: a\n\n".utf8)
        let events = parser.parse(bytes.lazy.map { $0 })
        #expect(events == [ServerSentEvent(data: "a")])
    }
}
