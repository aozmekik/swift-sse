#if !canImport(FoundationNetworking)
import Foundation
import Testing

@testable import SSE

/// End-to-end tests through a real `URLSession`, served by `StubURLProtocol`.
///
/// Every test runs against both transports: `URLSession.bytes(for:)` (the Apple default) and the
/// `URLSessionDataDelegate` bridge (the Linux default), so the delegate code path is exercised on
/// Apple platforms too.
@Suite("URLSession transports")
struct URLSessionTransportTests {
    enum Kind: String, CaseIterable, Sendable {
        case bytes
        case delegate
    }

    private func source(
        _ server: StubURLProtocol.Server,
        _ kind: Kind,
        reconnection: ReconnectionPolicy? = .disabled
    ) -> EventSource {
        let session = StubURLProtocol.makeSession()
        let transport: any EventStreamTransport =
            switch kind {
            case .bytes: URLSessionBytesTransport(session: session)
            case .delegate: URLSessionDelegateTransport(session: session)
            }
        return EventSource(
            request: URLRequest(url: server.url),
            reconnection: reconnection,
            lastEventID: "",
            environment: .init(transport: transport, sleep: { _ in }, random: { 0 })
        )
    }

    @Test("Events are streamed and the request carries the SSE headers", arguments: Kind.allCases)
    func streamsEvents(kind: Kind) async throws {
        let server = StubURLProtocol.Server([
            .init(chunks: ["data: a\r\n", "\r\nid: 2\r\ndata: b", "\r\n\r\n"])
        ])
        let (events, error) = await collect(source(server, kind))

        #expect(error == nil)
        #expect(
            events == [ServerSentEvent(data: "a"), ServerSentEvent(data: "b", lastEventID: "2")])
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }

    @Test("Reconnection sends Last-Event-ID", arguments: Kind.allCases)
    func reconnects(kind: Kind) async throws {
        let server = StubURLProtocol.Server([
            .init(chunks: ["id: 41\ndata: a\n\n"]),
            .init(chunks: ["data: b\n\n"]),
        ])
        let (events, _) = await collect(source(server, kind, reconnection: .default), limit: 2)

        #expect(events.map(\.data) == ["a", "b"])
        #expect(server.requests.count == 2)
        #expect(server.requests.last?.value(forHTTPHeaderField: "Last-Event-ID") == "41")
    }

    @Test("A non-200 status throws with the response body", arguments: Kind.allCases)
    func errorStatus(kind: Kind) async throws {
        let server = StubURLProtocol.Server([
            .init(
                status: 401, headers: ["Content-Type": "application/json"],
                chunks: ["{\"error\":\"invalid key\"}"])
        ])
        let (_, error) = await collect(source(server, kind, reconnection: .default))

        guard case .unexpectedStatusCode(401, let response, let body)? = error as? EventSourceError
        else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(response.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(String(decoding: body, as: UTF8.self) == "{\"error\":\"invalid key\"}")
        #expect(server.requests.count == 1)
    }

    @Test("A wrong content type throws", arguments: Kind.allCases)
    func wrongContentType(kind: Kind) async throws {
        let server = StubURLProtocol.Server([
            .init(headers: ["Content-Type": "text/html"], chunks: ["<html>"])
        ])
        let (_, error) = await collect(source(server, kind))

        guard case .unexpectedContentType("text/html", _, _)? = error as? EventSourceError else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
    }

    @Test("204 No Content ends the sequence", arguments: Kind.allCases)
    func noContent(kind: Kind) async throws {
        let server = StubURLProtocol.Server([.init(status: 204, headers: [:])])
        let (events, error) = await collect(source(server, kind, reconnection: .default))

        #expect(events.isEmpty)
        #expect(error == nil)
    }

    @Test(
        "Cancelling the task cancels the request",
        .timeLimit(.minutes(1)),
        arguments: Kind.allCases
    )
    func cancellation(kind: Kind) async throws {
        let server = StubURLProtocol.Server([.init(chunks: ["data: a\n\n"], hangs: true)])
        let events = source(server, kind)
        let (received, receivedContinuation) = AsyncStream.makeStream(of: Void.self)

        let task = Task {
            for try await _ in events {
                receivedContinuation.yield()
            }
        }
        for await _ in received { break }
        task.cancel()

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        for await _ in server.stops { break }  // The URL loading system stopped the load.
        #expect(server.stoppedLoads == 1)
    }

    @Test(
        "Breaking out of the loop cancels the request",
        .timeLimit(.minutes(1)),
        arguments: Kind.allCases
    )
    func breakCancels(kind: Kind) async throws {
        let server = StubURLProtocol.Server([.init(chunks: ["data: a\n\n"], hangs: true)])
        let (events, error) = await collect(source(server, kind), limit: 1)

        #expect(events.map(\.data) == ["a"])
        #expect(error == nil)
        for await _ in server.stops { break }
        #expect(server.stoppedLoads == 1)
    }

    @Test("The public initializer streams through the given session")
    func publicInitializer() async throws {
        let server = StubURLProtocol.Server([.init(chunks: ["data: hello\n\n"])])
        let source = EventSource(
            request: URLRequest(url: server.url),
            session: StubURLProtocol.makeSession(),
            reconnection: .disabled
        )
        let (events, error) = await collect(source)

        #expect(error == nil)
        #expect(events == [ServerSentEvent(data: "hello")])
    }
}
#endif
