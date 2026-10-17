import SSE
import Testing

/// Randomized differential tests: `EventStreamParser`, fed random chunkings of random streams,
/// must agree with `ReferenceParser` on the whole stream.
///
/// The generator is seeded, so a failure reports a seed that reproduces it.
@Suite("Parser properties")
struct ParserPropertyTests {
    static let caseCount = 2_000

    @Test("Random streams and random chunkings agree with the reference parser")
    func differential() {
        var failures: [UInt64] = []
        for seed in 0..<UInt64(Self.caseCount) {
            var random = SplitMix64(seed: seed)
            let stream = Self.randomStream(using: &random)
            let lastEventID = Bool.random(using: &random) ? "" : "seed"
            let expected = ReferenceParser.parse(stream, lastEventID: lastEventID)

            var splits: [Int] = []
            let splitCount = Int.random(in: 0...8, using: &random)
            for _ in 0..<splitCount where !stream.isEmpty {
                splits.append(Int.random(in: 0...stream.count, using: &random))
            }
            let actual = parse(stream, splitAt: splits, lastEventID: lastEventID)
            if actual != expected {
                failures.append(seed)
            }
        }
        #expect(failures.count == 0, "first failing seeds: \(failures.prefix(10))")
    }

    @Test("Byte-at-a-time parsing agrees with single-chunk parsing")
    func bytewiseEqualsWhole() {
        for seed in 0..<UInt64(300) {
            var random = SplitMix64(seed: seed &+ 1_000_000)
            let stream = Self.randomStream(using: &random)
            #expect(parseBytewise(stream) == parse(stream), "seed \(seed)")
        }
    }

    // MARK: Generator

    private static let fieldNames = [
        "data", "data", "data", "event", "id", "retry", "Data", "dat", "datax", "foo", "",
    ]

    private static let valueFragments: [[UInt8]] = [
        Array("hello".utf8), Array(" ".utf8), Array("  ".utf8), Array(":".utf8),
        Array("\t".utf8), Array("{\"k\": [1, 2]}".utf8), Array("\u{00E9}".utf8),
        Array("\u{1F600}".utf8), Array("123".utf8), Array("0".utf8), [0x00], [0xFF],
        [0xF0, 0x9F], [0xEF, 0xBB, 0xBF], [0xC0, 0x80],
    ]

    private static let terminators: [[UInt8]] = [[0x0A], [0x0D], [0x0D, 0x0A]]

    static func randomStream(using random: inout SplitMix64) -> [UInt8] {
        var bytes: [UInt8] = []
        let byteOrderMarks = Int.random(in: 0...6, using: &random)
        if byteOrderMarks >= 4 {
            for _ in 0..<(byteOrderMarks - 3) {
                bytes += [0xEF, 0xBB, 0xBF]
            }
        }

        let lineCount = Int.random(in: 0...24, using: &random)
        for _ in 0..<lineCount {
            switch Int.random(in: 0..<10, using: &random) {
            case 0, 1:
                break  // Empty line: dispatch.
            case 2:
                bytes += Array(":".utf8) + randomValue(using: &random)
            default:
                let name = fieldNames.randomElement(using: &random) ?? "data"
                bytes += Array(name.utf8)
                switch Int.random(in: 0..<4, using: &random) {
                case 0:
                    break  // No colon: the value is empty.
                case 1:
                    bytes += Array(":".utf8)
                default:
                    bytes += Array(": ".utf8)
                }
                bytes += randomValue(using: &random)
            }
            bytes += terminators.randomElement(using: &random) ?? [0x0A]
        }

        if Bool.random(using: &random) {
            bytes += Array("data: unterminated".utf8)  // Must be discarded at the end.
        }
        return bytes
    }

    private static func randomValue(using random: inout SplitMix64) -> [UInt8] {
        var value: [UInt8] = []
        for _ in 0..<Int.random(in: 0...4, using: &random) {
            value += valueFragments.randomElement(using: &random) ?? []
        }
        return value
    }
}
