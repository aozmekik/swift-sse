import Foundation
import Testing

@testable import SSE

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One scripted outcome of `EventStreamTransport.connect(_:)`.
enum Script: Sendable {
    /// How a scripted body ends.
    enum End: Sendable {
        /// The server closes the stream.
        case close
        /// The connection fails with an error.
        case fail(URLError)
        /// The body stays open until the connection is cancelled.
        case hang
    }

    /// The connection attempt itself fails.
    case connectFails(URLError)
    /// The response is not an HTTP response.
    case nonHTTPResponse
    /// The server responds.
    case respond(status: Int, contentType: String?, chunks: [String], end: End)

    /// A 200 `text/event-stream` response.
    static func stream(_ chunks: String..., end: End = .close) -> Script {
        .respond(status: 200, contentType: "text/event-stream", chunks: chunks, end: end)
    }
}

/// An `EventStreamTransport` that replays scripts and records what the client did.
final class StubTransport: EventStreamTransport {
    private struct State {
        var scripts: [Script]
        var requests: [URLRequest] = []
        var cancelledConnections = 0
        var openContinuations: [AsyncThrowingStream<Data, any Error>.Continuation] = []
    }

    private let state: LockedState<State>

    init(_ scripts: [Script]) {
        state = LockedState(State(scripts: scripts))
    }

    /// The requests sent so far, in order.
    var requests: [URLRequest] { state.withLock(\.requests) }

    /// How many connections the client cancelled (closing an open or finished connection).
    var cancelledConnections: Int { state.withLock(\.cancelledConnections) }

    func connect(_ request: URLRequest) async throws -> EventStreamConnection {
        let script: Script? = state.withLock { state in
            state.requests.append(request)
            return state.scripts.isEmpty ? nil : state.scripts.removeFirst()
        }
        guard let script else {
            Issue.record("Unexpected connection attempt \(requests.count)")
            throw URLError(.resourceUnavailable)
        }
        switch script {
        case .connectFails(let error):
            throw error
        case .nonHTTPResponse:
            let response = URLResponse(
                url: testURL, mimeType: "text/event-stream", expectedContentLength: 0,
                textEncodingName: nil)
            let (body, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
            continuation.finish()
            return EventStreamConnection(response: response, body: .chunks(body)) {}
        case .respond(let status, let contentType, let chunks, let end):
            let url = request.url ?? URL(fileURLWithPath: "/")
            let headers = contentType.map { ["Content-Type": $0] } ?? [:]
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            else {
                throw URLError(.badServerResponse)
            }
            let (body, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
            for chunk in chunks {
                continuation.yield(Data(chunk.utf8))
            }
            switch end {
            case .close:
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            case .hang:
                // Keep the continuation alive so the stream stays open.
                state.withLock { $0.openContinuations.append(continuation) }
            }
            return EventStreamConnection(response: response, body: .chunks(body)) {
                [state] in
                state.withLock { $0.cancelledConnections += 1 }
                // Like a real transport, cancelling ends a body that is still open.
                continuation.finish(throwing: URLError(.cancelled))
            }
        }
    }
}

/// Records reconnection delays instead of sleeping.
final class RecordingSleeper: Sendable {
    private let delays = LockedState<[Duration]>([])
    private let started: AsyncStream<Void>.Continuation
    /// Yields each time a sleep begins.
    let sleepStarted: AsyncStream<Void>
    /// Whether sleeps block until the task is cancelled.
    let blocksUntilCancelled: Bool

    init(blocksUntilCancelled: Bool = false) {
        (sleepStarted, started) = AsyncStream.makeStream(of: Void.self)
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    /// The delays requested so far.
    var recorded: [Duration] { delays.withLock { $0 } }

    @Sendable func sleep(_ duration: Duration) async throws {
        delays.withLock { $0.append(duration) }
        started.yield()
        if blocksUntilCancelled {
            // Not a timing dependency: the test cancels the task while this is suspended.
            try await Task.sleep(for: .seconds(3_600))
        }
        try Task.checkCancellation()
    }
}

extension EventSource {
    /// An event source with injected transport, sleeper and jitter.
    static func stubbed(
        _ transport: StubTransport,
        method: String = "GET",
        reconnection: ReconnectionPolicy? = nil,
        lastEventID: String = "",
        sleeper: RecordingSleeper = RecordingSleeper(),
        random: Double = 0,
        errorBodyTimeout: Duration = .seconds(1)
    ) -> EventSource {
        var request = URLRequest(url: testURL)
        request.httpMethod = method
        return EventSource(
            request: request,
            reconnection: reconnection,
            lastEventID: lastEventID,
            environment: Environment(
                transport: transport,
                sleep: sleeper.sleep,
                random: { random },
                errorBodyTimeout: errorBodyTimeout
            )
        )
    }
}

extension URLRequest {
    /// The last event ID that this request's `Last-Event-ID` header puts on the wire, decoded
    /// from those bytes as UTF-8, or `nil` if the request has no such header.
    ///
    /// On Apple platforms the header value spells the UTF-8 bytes as ISO-8859-1 characters (see
    /// `EventSource.lastEventIDHeaderValue(_:)`), so comparing the header string with the ID
    /// would test the spelling instead of what the server receives.
    var sentLastEventID: String? {
        guard let value = value(forHTTPHeaderField: "Last-Event-ID") else { return nil }
        #if canImport(FoundationNetworking)
        return value
        #else
        let bytes = value.unicodeScalars.map { scalar in
            guard let byte = UInt8(exactly: scalar.value) else {
                preconditionFailure("Last-Event-ID contains U+\(String(scalar.value, radix: 16))")
            }
            return byte
        }
        return String(decoding: bytes, as: UTF8.self)
        #endif
    }
}

/// The URL of stubbed requests.
let testURL: URL = {
    guard let url = URL(string: "https://example.test/stream") else {
        preconditionFailure("invalid test URL")
    }
    return url
}()

/// Collects events until the sequence ends, the limit is reached, or it throws.
func collect(
    _ source: EventSource,
    limit: Int = .max
) async -> (events: [ServerSentEvent], error: (any Error)?) {
    var events: [ServerSentEvent] = []
    do {
        for try await event in source {
            events.append(event)
            if events.count == limit {
                break
            }
        }
        return (events, nil)
    } catch {
        return (events, error)
    }
}
