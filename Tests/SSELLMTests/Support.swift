import Foundation
import SSE
import SSELLM
import Testing

/// A Server-Sent Event whose data is `json`.
func event(_ json: String, type: String = ServerSentEvent.defaultType) -> ServerSentEvent {
    ServerSentEvent(type: type, data: json)
}

/// Counts how many events a consumer pulled.
final class PullCounter {
    var pulls = 0
}

/// A finite sequence of events that records how far it was read.
struct ScriptedEvents: AsyncSequence {
    typealias Element = ServerSentEvent

    let events: [ServerSentEvent]
    let counter: PullCounter

    func makeAsyncIterator() -> Iterator {
        Iterator(events: events, counter: counter)
    }

    struct Iterator: AsyncIteratorProtocol {
        let events: [ServerSentEvent]
        let counter: PullCounter
        var position = 0

        mutating func next() async throws -> ServerSentEvent? {
            counter.pulls += 1
            guard position < events.count else { return nil }
            defer { position += 1 }
            return events[position]
        }
    }
}

/// Parses a fixture file from `examples/fixtures` into events.
func fixtureEvents(_ name: String) throws -> [ServerSentEvent] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SSELLMTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
    let url = root.appendingPathComponent("examples/fixtures/\(name)")
    let bytes = try Data(contentsOf: url)
    var parser = EventStreamParser()
    let events = parser.parse(bytes)
    parser.finish()
    return events
}

/// Runs `body` and returns the `LLMStreamError` it throws, recording an issue otherwise.
func llmError(_ body: () async throws -> Void) async -> LLMStreamError? {
    do {
        try await body()
        Issue.record("expected an LLMStreamError")
        return nil
    } catch let error as LLMStreamError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

/// Decodes chat completion chunks from JSON payloads, recording an issue for anything else.
func openAIChunks(_ payloads: [String]) throws -> [OpenAIChatCompletionChunk] {
    try payloads.compactMap { json in
        guard case .chunk(let chunk) = try OpenAIChatStreamEvent(decoding: event(json)) else {
            Issue.record("expected a chunk for \(json)")
            return nil
        }
        return chunk
    }
}
