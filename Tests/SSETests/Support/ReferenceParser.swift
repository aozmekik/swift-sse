import SSE

/// A deliberately naive transliteration of the standard's algorithm, used as a test oracle.
///
/// It decodes the whole stream to a `String` first, as section 9.2.6 describes ("streams must be
/// decoded using the UTF-8 decode algorithm"), then splits lines and interprets fields on Unicode
/// scalars. It shares no code with `EventStreamParser`, which works on bytes and incrementally.
enum ReferenceParser {
    static func parse(_ bytes: [UInt8], lastEventID initialID: String = "") -> ParseResult {
        var scalars = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        if scalars.first == "\u{FEFF}" {
            scalars.removeFirst()
        }

        // Split into complete lines; whatever follows the last terminator is discarded.
        var lines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\r" {
                lines.append(current)
                current = []
                if index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    index += 1
                }
            } else if scalar == "\n" {
                lines.append(current)
                current = []
            } else {
                current.append(scalar)
            }
            index += 1
        }

        var events: [ServerSentEvent] = []
        var data = ""
        var eventType = ""
        var lastEventIDBuffer = initialID
        var lastEventID = initialID
        var reconnectionTime: Duration?

        for line in lines {
            if line.isEmpty {
                lastEventID = lastEventIDBuffer
                if data.isEmpty {
                    eventType = ""
                    continue
                }
                if data.hasSuffix("\n") {
                    data.removeLast()
                }
                events.append(
                    ServerSentEvent(
                        type: eventType.isEmpty ? "message" : eventType,
                        data: data,
                        lastEventID: lastEventID
                    ))
                data = ""
                eventType = ""
                continue
            }
            if line.first == ":" {
                continue
            }
            let name: String
            var value: String
            if let colon = line.firstIndex(of: ":") {
                name = String(String.UnicodeScalarView(line[..<colon]))
                value = String(String.UnicodeScalarView(line[(colon + 1)...]))
                if value.unicodeScalars.first == " " {
                    value.unicodeScalars.removeFirst()
                }
            } else {
                name = String(String.UnicodeScalarView(line))
                value = ""
            }
            switch name {
            case "event":
                eventType = value
            case "data":
                data += value + "\n"
            case "id":
                if !value.unicodeScalars.contains("\0") {
                    lastEventIDBuffer = value
                }
            case "retry":
                let digits = value.unicodeScalars
                if !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) {
                    // Saturate like the implementation; the oracle only needs to agree on it.
                    let milliseconds = Int64(value) ?? .max
                    reconnectionTime = .milliseconds(milliseconds)
                }
            default:
                break
            }
        }
        return ParseResult(
            events: events, lastEventID: lastEventID, reconnectionTime: reconnectionTime)
    }
}
