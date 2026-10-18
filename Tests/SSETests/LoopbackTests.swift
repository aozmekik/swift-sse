import Foundation
import Testing

@testable import SSE

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end tests over real TCP connections to a ``LoopbackServer``.
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
}
