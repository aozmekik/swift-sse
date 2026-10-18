// sse-benchmark: measures EventStreamParser throughput on large synthetic streams, and how the
// SSELLM accumulators scale with the number of deltas.
//
//   swift run -c release sse-benchmark            # full run (64 MiB per workload)
//   swift run -c release sse-benchmark --quick    # small smoke run, numbers not meaningful
//
// Every workload is generated in memory, deterministically, before timing starts. Each
// configuration is run once to warm up and then `runs` times; the tables report the median and
// the range. Only parsing, or only accumulation, is timed: no I/O, no networking, no JSON
// decoding.

import Foundation
import SSE
import SSELLM

struct Workload {
    var name: String
    var description: String
    var bytes: [UInt8]
}

/// Repeats `block(i)` until the stream reaches `size` bytes.
func makeStream(size: Int, block: (Int) -> String) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(size + 4_096)
    var index = 0
    while bytes.count < size {
        bytes += block(index).utf8
        index += 1
    }
    return bytes
}

func workloads(size: Int) -> [Workload] {
    let llm = makeStream(size: size) { index in
        let token = ["The", " quick", " brown", " fox", " jumps", " over", " lazy", " dogs"][
            index % 8]
        return
            "data: {\"id\":\"chatcmpl-0001\",\"object\":\"chat.completion.chunk\","
            + "\"created\":1760745600,\"model\":\"example-model\",\"choices\":[{\"index\":0,"
            + "\"delta\":{\"content\":\"\(token)\"},\"finish_reason\":null}]}\n\n"
    }
    let line = String(repeating: "lorem ipsum ", count: 6)
    let multiline = makeStream(size: size) { index in
        var block = "id: \(index)\r\nevent: update\r\n"
        for _ in 0..<8 {
            block += "data: \(line)\r\n"
        }
        return block + "\r\n"
    }
    let tiny = makeStream(size: size / 4) { _ in "data: x\n\n" }
    return [
        Workload(
            name: "llm-chunks",
            description: "OpenAI-style chat.completion.chunk events, LF",
            bytes: llm),
        Workload(
            name: "multi-line",
            description: "id + event + 8 data lines of 72 bytes, CRLF",
            bytes: multiline),
        Workload(name: "tiny", description: "`data: x` events, LF", bytes: tiny),
    ]
}

struct Measurement {
    var seconds: [Double]
    var events: Int
    var checksum: Int
}

func measure(_ bytes: [UInt8], chunkSize: Int, runs: Int) -> Measurement {
    var seconds: [Double] = []
    var events = 0
    var checksum = 0
    let clock = ContinuousClock()
    for run in 0...runs {
        var parser = EventStreamParser()
        var runEvents = 0
        var runChecksum = 0
        let elapsed = clock.measure {
            bytes.withUnsafeBufferPointer { buffer in
                var start = 0
                while start < buffer.count {
                    let end = min(start + chunkSize, buffer.count)
                    for event in parser.parse(UnsafeBufferPointer(rebasing: buffer[start..<end])) {
                        runEvents += 1
                        runChecksum &+= event.data.utf8.count
                    }
                    start = end
                }
            }
            parser.finish()
        }
        if run > 0 {  // Run 0 is the warm-up.
            let (whole, fraction) = elapsed.components
            seconds.append(Double(whole) + Double(fraction) * 1e-18)
        }
        events = runEvents
        checksum = runChecksum
    }
    return Measurement(seconds: seconds.sorted(), events: events, checksum: checksum)
}

/// Times `body` once to warm up and then `runs` times; returns the sorted durations in seconds.
func time(runs: Int, _ body: () throws -> Void) throws -> [Double] {
    let clock = ContinuousClock()
    var seconds: [Double] = []
    for run in 0...runs {
        var failure: (any Error)?
        let elapsed = clock.measure {
            do { try body() } catch { failure = error }
        }
        if let failure { throw failure }
        if run > 0 {
            let (whole, fraction) = elapsed.components
            seconds.append(Double(whole) + Double(fraction) * 1e-18)
        }
    }
    return seconds.sorted()
}

/// Accumulates `count` text deltas of four bytes into each accumulator; with a linear
/// implementation the time per delta stays flat as `count` grows.
func measureAccumulators(counts: [Int], runs: Int) throws {
    print("")
    print("Accumulators: \(runs) runs after one warm-up, median (min-max), 4-byte text deltas.")
    print("")
    print("| Accumulator | Deltas | Total (ms) | ns per delta |")
    print("|---|---:|---:|---:|")
    for count in counts {
        let chunks = (0..<count).map { _ in
            OpenAIChatCompletionChunk(choices: [.init(delta: .init(content: "abcd"))])
        }
        let openAI = try time(runs: runs) {
            var accumulator = OpenAIChatCompletionAccumulator()
            for chunk in chunks {
                accumulator.add(chunk)
            }
            precondition(accumulator.text.utf8.count == count * 4)
        }
        let events: [AnthropicStreamEvent] =
            [.contentBlockStart(index: 0, block: .text(""))]
            + (0..<count).map { _ in .contentBlockDelta(index: 0, delta: .text("abcd")) }
        let anthropic = try time(runs: runs) {
            var message = AnthropicMessageAccumulator()
            for event in events {
                try message.add(event)
            }
            precondition(message.text.utf8.count == count * 4)
        }
        for (name, seconds) in [("OpenAI", openAI), ("Anthropic", anthropic)] {
            let median = seconds[seconds.count / 2]
            let fastest = format(seconds[0] * 1e3, decimals: 1)
            let slowest = format(seconds[seconds.count - 1] * 1e3, decimals: 1)
            let total = "\(format(median * 1e3, decimals: 1)) (\(fastest)-\(slowest))"
            print("| \(name) | \(count) | \(total) | \(format(median / Double(count) * 1e9)) |")
        }
    }
}

func format(_ value: Double, decimals: Int = 0) -> String {
    String(format: "%.\(decimals)f", value)
}

let quick = CommandLine.arguments.contains("--quick")
let size = quick ? 1 << 20 : 64 << 20
let runs = quick ? 2 : 7
let chunkSizes = [64, 1_024, 16_384]

print("EventStreamParser throughput, \(runs) runs after one warm-up, median (min-max).")
print("Stream size: \(size >> 20) MiB per workload (the tiny workload is a quarter of that).")
print("")
print("| Workload | Chunk size | MiB/s | Events/s (millions) | Events |")
print("|---|---:|---:|---:|---:|")
for workload in workloads(size: size) {
    let mebibytes = Double(workload.bytes.count) / Double(1 << 20)
    for chunkSize in chunkSizes {
        let result = measure(workload.bytes, chunkSize: chunkSize, runs: runs)
        let median = result.seconds[result.seconds.count / 2]
        let fastest = result.seconds[0]
        let slowest = result.seconds[result.seconds.count - 1]
        let throughput =
            "\(format(mebibytes / median)) (\(format(mebibytes / slowest))-\(format(mebibytes / fastest)))"
        let eventRate = format(Double(result.events) / median / 1e6, decimals: 2)
        print(
            "| \(workload.name) | \(chunkSize) B | \(throughput) | \(eventRate) | \(result.events) |"
        )
        precondition(result.checksum > 0, "the parser produced no data")
    }
}
print("")
for workload in workloads(size: 1_024) {
    print("- \(workload.name): \(workload.description)")
}

try measureAccumulators(counts: quick ? [1_000, 4_000] : [5_000, 20_000, 80_000], runs: runs)
