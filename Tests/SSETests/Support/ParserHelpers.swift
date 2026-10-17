import SSE

/// The outcome of parsing a complete stream.
struct ParseResult: Equatable {
    var events: [ServerSentEvent]
    var lastEventID: String
    var reconnectionTime: Duration?
}

/// Parses `bytes` as one complete stream, fed to the parser in the given chunks.
func parse(_ bytes: [UInt8], splitAt splits: [Int] = [], lastEventID: String = "") -> ParseResult {
    var parser = EventStreamParser(lastEventID: lastEventID)
    var events: [ServerSentEvent] = []
    var start = 0
    for split in splits.sorted() + [bytes.count] where split >= start {
        events += parser.parse(bytes[start..<split])
        start = split
    }
    parser.finish()
    return ParseResult(
        events: events,
        lastEventID: parser.lastEventID,
        reconnectionTime: parser.reconnectionTime
    )
}

/// Parses `text` (UTF-8 encoded) as one complete stream.
func parse(_ text: String, lastEventID: String = "") -> ParseResult {
    parse(Array(text.utf8), lastEventID: lastEventID)
}

/// Parses `bytes` one byte per call.
func parseBytewise(_ bytes: [UInt8]) -> ParseResult {
    parse(bytes, splitAt: Array(bytes.indices))
}

/// The data of each event.
func dataOf(_ result: ParseResult) -> [String] {
    result.events.map(\.data)
}

/// A small, fast, seedable generator, so that randomized tests are reproducible.
///
/// SplitMix64, by Guy L. Steele Jr., Doug Lea and Christine H. Flood ("Fast splittable
/// pseudorandom number generators", OOPSLA 2014).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
