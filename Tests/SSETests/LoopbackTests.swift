import Foundation
import Testing

@testable import SSE

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end tests with the production transports and real `URLSession`s, over TCP connections
/// to a ``LoopbackServer`` (or none, where the URL loading system fails first).
///
/// These check what only the bytes on the wire show: how header values are encoded, which
/// headers the URL loading system adds, and the transport's flow control.
@Suite("Loopback HTTP")
struct LoopbackTests {
    /// The production transports available on this platform.
    enum Transport: String, CaseIterable, Sendable {
        #if !canImport(FoundationNetworking)
        case bytes
        #endif
        case delegate

        func make(_ session: URLSession) -> any EventStreamTransport {
            switch self {
            #if !canImport(FoundationNetworking)
            case .bytes: URLSessionBytesTransport(session: session)
            #endif
            case .delegate: URLSessionDelegateTransport(session: session)
            }
        }
    }

    private func source(
        _ url: URL,
        _ transport: Transport,
        reconnection: ReconnectionPolicy? = .default,
        lastEventID: String = ""
    ) -> EventSource {
        EventSource(
            request: URLRequest(url: url),
            reconnection: reconnection,
            lastEventID: lastEventID,
            environment: .init(
                transport: transport.make(URLSession(configuration: .ephemeral)),
                sleep: { _ in },
                random: { 0 }
            )
        )
    }

    @Test(
        "Last-Event-ID reaches the server as UTF-8 (web-platform-tests format-field-id-2)",
        arguments: Transport.allCases,
        ["\u{2026}", "caf\u{E9}\u{2026}z", "\u{65E5}\u{1F600}", "41"]
    )
    func lastEventIDIsUTF8OnTheWire(transport: Transport, id: String) async throws {
        // Like the WPT resource: a request without Last-Event-ID gets an event with `id`; a
        // request with one gets an event whose data is the header's raw bytes.
        let received = LockedState<[[UInt8]?]>([])
        let server = try LoopbackServer { connection in
            guard let head = connection.readRequestHead() else { return }
            let lastEventID = head.value(of: "Last-Event-ID")
            received.withLock { $0.append(lastEventID) }
            connection.writeEventStreamHead()
            if let lastEventID, !lastEventID.isEmpty {
                connection.write(Array("data: ".utf8) + lastEventID + Array("\n\n".utf8))
            } else {
                connection.write("id: \(id)\nretry: 200\ndata: hello\n\n")
            }
        }
        defer { server.stop() }

        let (events, error) = await collect(source(server.url(), transport), limit: 3)

        #expect(error == nil)
        #expect(events.map(\.data) == ["hello", id, id])
        #expect(events.map(\.lastEventID) == [id, id, id])
        #expect(received.withLock { $0 } == [nil, Array(id.utf8), Array(id.utf8)])
    }

    @Test(
        "Requests carry Accept and no-cache headers (web-platform-tests request-cache-control)",
        arguments: Transport.allCases
    )
    func requestHeadersOnTheWire(transport: Transport) async throws {
        let heads = LockedState<[LoopbackRequestHead]>([])
        let server = try LoopbackServer { connection in
            guard let head = connection.readRequestHead() else { return }
            heads.withLock { $0.append(head) }
            connection.writeEventStreamHead()
            connection.write("data: x\n\n")
        }
        defer { server.stop() }

        let events = source(server.url(), transport, reconnection: .disabled)
        let (received, error) = await collect(events)

        #expect(error == nil)
        #expect(received.map(\.data) == ["x"])
        let first = heads.withLock { $0.first }
        let head = try #require(first)
        #expect(head.value(of: "Accept") == Array("text/event-stream".utf8))
        #expect(head.value(of: "Cache-Control") == Array("no-cache".utf8))
        #expect(head.value(of: "Pragma") == Array("no-cache".utf8))
        #expect(head.value(of: "Last-Event-ID") == nil)
    }

    @Test(
        "Responses are not stored in the session's URL cache, whatever the request's headers",
        arguments: Transport.allCases
    )
    func responsesAreNotCached(transport: Transport) async throws {
        let body = "data: cached?\n\n"
        let server = try LoopbackServer { connection in
            guard connection.readRequestHead() != nil else { return }
            // A complete, cacheable response: without the no-store delegate, URLSession stores it.
            connection.write(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
        }
        defer { server.stop() }
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        // The default `Cache-Control: no-cache` already keeps URLSession from storing the
        // response; a caller's own header must not bring storage back.
        var request = URLRequest(url: server.url())
        request.setValue("max-age=0", forHTTPHeaderField: "Cache-Control")
        let source = EventSource(
            request: request,
            reconnection: .disabled,
            lastEventID: "",
            environment: .init(
                transport: transport.make(URLSession(configuration: configuration)),
                sleep: { _ in },
                random: { 0 }
            )
        )

        let (events, error) = await collect(source)

        #expect(error == nil)
        #expect(events.map(\.data) == ["cached?"])
        #expect(cache.cachedResponse(for: URLRequest(url: server.url())) == nil)
    }

    @Test(
        "A consumer that stops reading slows the server down instead of buffering without bound",
        .timeLimit(.minutes(1)),
        arguments: Transport.allCases
    )
    func backPressure(transport: Transport) async throws {
        // The server writes numbered 1 KiB events as fast as the connection accepts them, so
        // the bytes it manages to write while the consumer is paused are what the client
        // buffered (plus the kernel's socket buffers).
        let sent = LockedState(0)
        let server = try LoopbackServer { connection in
            guard connection.readRequestHead() != nil else { return }
            connection.writeEventStreamHead()
            let padding = String(repeating: "x", count: 1_000)
            var id = 0
            while true {
                var block = ""
                for _ in 0..<64 {
                    id += 1
                    block += "id: \(id)\ndata: \(padding)\n\n"
                }
                guard connection.write(block) else { return }
                sent.withLock { $0 += block.utf8.count }
            }
        }
        defer { server.stop() }

        var iterator = source(server.url(), transport, reconnection: .disabled)
            .makeAsyncIterator()
        _ = try await iterator.next()
        // Real time, but not a timing assumption: a transport without flow control receives
        // hundreds of MiB in this pause, one with flow control a few MiB however long it lasts.
        try await Task.sleep(for: .seconds(1))
        let sentDuringPause = sent.withLock { $0 }
        #expect(sentDuringPause < 32 << 20, "the client kept reading while nobody consumed")

        // Reading resumes after the pause, without losing or reordering events.
        for expected in 2...20_001 {
            let event = try #require(try await iterator.next())
            guard event.lastEventID == String(expected) else {
                Issue.record("expected event \(expected), got \(event.lastEventID)")
                break
            }
        }
    }

    @Test(
        "An unsupported URL scheme fails at once instead of reconnecting forever",
        .timeLimit(.minutes(1)),
        arguments: Transport.allCases
    )
    func unsupportedSchemeFails(transport: Transport) async throws {
        let url = try #require(URL(string: "foo://example.test/stream"))
        let (events, error) = await collect(source(url, transport, reconnection: .default))

        #expect(events.isEmpty)
        guard case .connectionFailed(let underlying)? = error as? EventSourceError else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect((underlying as? URLError)?.code == .unsupportedURL)
    }
}
