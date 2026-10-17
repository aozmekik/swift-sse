/// An incremental parser for the `text/event-stream` format.
///
/// `EventStreamParser` implements the parsing and interpretation rules of the WHATWG HTML Living
/// Standard, section 9.2.5 "Parsing an event stream" and section 9.2.6 "Interpreting an event
/// stream". It is a pure value type with no I/O: feed it bytes from any source (a socket, a file,
/// a test fixture) in chunks of any size and it returns the events whose blocks are complete.
///
/// ```swift
/// var parser = EventStreamParser()
/// for chunk in chunks {
///     for event in parser.parse(chunk) {
///         print(event.type, event.data)
///     }
/// }
/// parser.finish()  // end of stream: an unterminated final block is discarded
/// ```
///
/// The parser handles:
///
/// - `CRLF`, `LF` and `CR` line endings, including a `CRLF` pair split across two chunks;
/// - a single leading UTF-8 byte order mark, also when it is split across chunks;
/// - comment lines (starting with `:`), which are ignored;
/// - the `event`, `data`, `id` and `retry` fields, with one optional space after the colon;
/// - multi-line `data`, joined with `"\n"`;
/// - `id` values containing U+0000 NULL, which are ignored;
/// - `retry` values that are not purely ASCII digits, which are ignored;
/// - invalid UTF-8, which is replaced with U+FFFD as by the standard's UTF-8 decode.
///
/// The parser works on bytes and only decodes UTF-8 when it builds an event, so field names are
/// compared byte-for-byte (case-sensitively, as the standard requires) and line terminators can
/// never be confused with the inside of a multi-byte sequence.
public struct EventStreamParser: Sendable {
    /// The stream's *last event ID string*.
    ///
    /// The standard updates this value when an event is dispatched, from the last `id:` field
    /// seen. It is not reset between events, so it also applies to later events that have no
    /// `id:` field of their own. Send it to the server in the `Last-Event-ID` header when you
    /// reconnect.
    public private(set) var lastEventID: String

    /// The reconnection time most recently requested by the server with a `retry:` field, or
    /// `nil` if the stream has not sent a valid one.
    ///
    /// Values too large for a 64-bit millisecond count saturate at `Int64.max` milliseconds.
    public private(set) var reconnectionTime: Duration?

    /// Bytes of a line whose terminator has not been seen yet.
    private var pendingLine: [UInt8] = []
    /// The data buffer: every `data:` value of the current block, each followed by `LF`.
    private var dataBuffer: [UInt8] = []
    /// The event type buffer.
    private var eventTypeBuffer = ""
    /// The last event ID buffer, copied to ``lastEventID`` when a block is dispatched.
    private var lastEventIDBuffer: String
    /// Whether the previous chunk ended with `CR`, so a leading `LF` belongs to that terminator.
    private var skipsLeadingLineFeed = false
    /// Progress of matching the optional byte order mark at the start of the stream.
    private var byteOrderMark = ByteOrderMarkState.pending(matched: 0)

    /// Creates a parser positioned at the start of a stream.
    ///
    /// - Parameter lastEventID: The initial last event ID string. Pass the ID you sent in the
    ///   `Last-Event-ID` header when resuming a stream, so that events without an `id:` field keep
    ///   reporting it.
    public init(lastEventID: String = "") {
        self.lastEventID = lastEventID
        self.lastEventIDBuffer = lastEventID
    }

    /// Parses the next chunk of the stream.
    ///
    /// Chunks can be split anywhere, including inside a line terminator, a multi-byte UTF-8
    /// sequence or the byte order mark. Bytes after the last line terminator are kept until the
    /// next call.
    ///
    /// - Parameter bytes: The next bytes of the stream.
    /// - Returns: The events dispatched by blocks that this chunk completed, in stream order.
    public mutating func parse<Bytes: Sequence>(_ bytes: Bytes) -> [ServerSentEvent]
    where Bytes.Element == UInt8 {
        var events: [ServerSentEvent] = []
        let handled: Void? = bytes.withContiguousStorageIfAvailable { buffer in
            consume(buffer, into: &events)
        }
        if handled == nil {
            let contiguous = Array(bytes)
            contiguous.withUnsafeBufferPointer { buffer in
                consume(buffer, into: &events)
            }
        }
        return events
    }

    /// Signals the end of the stream.
    ///
    /// As the standard requires, any pending data is discarded: a final block that is not
    /// followed by an empty line is not dispatched, and an `id:` field in it does not change
    /// ``lastEventID``. ``lastEventID`` and ``reconnectionTime`` are kept, and the parser is ready
    /// to parse a new stream (for example after reconnecting), including its byte order mark.
    public mutating func finish() {
        pendingLine.removeAll(keepingCapacity: true)
        dataBuffer.removeAll(keepingCapacity: true)
        eventTypeBuffer = ""
        lastEventIDBuffer = lastEventID
        skipsLeadingLineFeed = false
        byteOrderMark = .pending(matched: 0)
    }
}

// MARK: - Implementation

extension EventStreamParser {
    private enum ByteOrderMarkState: Sendable {
        case pending(matched: Int)
        case done
    }

    private static let byteOrderMarkBytes: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let colon: UInt8 = 0x3A
    private static let space: UInt8 = 0x20
    private static let null: UInt8 = 0x00
    private static let digitZero: UInt8 = 0x30
    private static let digitNine: UInt8 = 0x39

    private mutating func consume(
        _ input: UnsafeBufferPointer<UInt8>,
        into events: inout [ServerSentEvent]
    ) {
        var position = input.startIndex
        let end = input.endIndex

        if case .pending(var matched) = byteOrderMark {
            while position < end, matched < Self.byteOrderMarkBytes.count {
                guard input[position] == Self.byteOrderMarkBytes[matched] else { break }
                matched += 1
                position += 1
            }
            if matched == Self.byteOrderMarkBytes.count {
                byteOrderMark = .done
            } else if position == end {
                // The chunk ended inside what may still become a byte order mark.
                byteOrderMark = .pending(matched: matched)
                return
            } else {
                // Not a byte order mark: the bytes matched so far are ordinary content. None of
                // them is a line terminator, so they start the first line.
                pendingLine.append(contentsOf: Self.byteOrderMarkBytes[..<matched])
                byteOrderMark = .done
            }
        }

        while position < end {
            if skipsLeadingLineFeed {
                skipsLeadingLineFeed = false
                if input[position] == Self.lineFeed {
                    position += 1
                    continue
                }
            }

            var terminator = position
            while terminator < end {
                let byte = input[terminator]
                // One comparison for the common case: every byte above CR is line content.
                if byte <= Self.carriageReturn,
                    byte == Self.carriageReturn || byte == Self.lineFeed
                {
                    break
                }
                terminator += 1
            }

            let content = UnsafeBufferPointer(rebasing: input[position..<terminator])
            guard terminator < end else {
                pendingLine.append(contentsOf: content)
                return
            }

            if pendingLine.isEmpty {
                processLine(content, into: &events)
            } else {
                pendingLine.append(contentsOf: content)
                var line: [UInt8] = []
                swap(&line, &pendingLine)
                line.withUnsafeBufferPointer { processLine($0, into: &events) }
                line.removeAll(keepingCapacity: true)
                swap(&line, &pendingLine)
            }

            skipsLeadingLineFeed = input[terminator] == Self.carriageReturn
            position = terminator + 1
        }
    }

    private mutating func processLine(
        _ line: UnsafeBufferPointer<UInt8>,
        into events: inout [ServerSentEvent]
    ) {
        guard let first = line.first else {
            dispatch(into: &events)
            return
        }
        if first == Self.colon {
            return  // Comment line.
        }

        let name: UnsafeBufferPointer<UInt8>
        let value: UnsafeBufferPointer<UInt8>
        if let colonIndex = line.firstIndex(of: Self.colon) {
            name = UnsafeBufferPointer(rebasing: line[..<colonIndex])
            var valueStart = colonIndex + 1
            if valueStart < line.endIndex, line[valueStart] == Self.space {
                valueStart += 1
            }
            value = UnsafeBufferPointer(rebasing: line[valueStart...])
        } else {
            name = line
            value = UnsafeBufferPointer(rebasing: line[line.endIndex...])
        }
        processField(name: name, value: value)
    }

    private mutating func processField(
        name: UnsafeBufferPointer<UInt8>,
        value: UnsafeBufferPointer<UInt8>
    ) {
        if Self.matches(name, "data") {
            dataBuffer.append(contentsOf: value)
            dataBuffer.append(Self.lineFeed)
        } else if Self.matches(name, "event") {
            eventTypeBuffer = String(decoding: value, as: UTF8.self)
        } else if Self.matches(name, "id") {
            if !value.contains(Self.null) {
                lastEventIDBuffer = String(decoding: value, as: UTF8.self)
            }
        } else if Self.matches(name, "retry") {
            if let milliseconds = Self.parseRetry(value) {
                reconnectionTime = .milliseconds(milliseconds)
            }
        }
        // Any other field name is ignored.
    }

    private mutating func dispatch(into events: inout [ServerSentEvent]) {
        lastEventID = lastEventIDBuffer
        guard !dataBuffer.isEmpty else {
            eventTypeBuffer = ""
            return
        }
        // Every data field appends LF, so the buffer always ends with the LF to remove.
        dataBuffer.removeLast()
        let data = String(decoding: dataBuffer, as: UTF8.self)
        let type = eventTypeBuffer.isEmpty ? ServerSentEvent.defaultType : eventTypeBuffer
        events.append(ServerSentEvent(type: type, data: data, lastEventID: lastEventID))
        dataBuffer.removeAll(keepingCapacity: true)
        eventTypeBuffer = ""
    }

    private static func matches(_ bytes: UnsafeBufferPointer<UInt8>, _ name: StaticString) -> Bool {
        guard bytes.count == name.utf8CodeUnitCount else { return false }
        return name.withUTF8Buffer { bytes.elementsEqual($0) }
    }

    /// Parses a `retry` value: ASCII digits only, at least one, saturating on overflow.
    private static func parseRetry(_ value: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard !value.isEmpty else { return nil }
        var result: Int64 = 0
        var saturated = false
        for byte in value {
            guard byte >= digitZero, byte <= digitNine else { return nil }
            guard !saturated else { continue }
            let (shifted, shiftOverflow) = result.multipliedReportingOverflow(by: 10)
            let (sum, sumOverflow) = shifted.addingReportingOverflow(Int64(byte - digitZero))
            if shiftOverflow || sumOverflow {
                saturated = true
                result = .max
            } else {
                result = sum
            }
        }
        return result
    }
}
