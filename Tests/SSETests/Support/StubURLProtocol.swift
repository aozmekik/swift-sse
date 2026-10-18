#if !canImport(FoundationNetworking)
import Foundation

@testable import SSE

/// A `URLProtocol` that serves scripted responses to a real `URLSession`.
///
/// Each test registers a ``Server`` under a unique host, so tests that run in parallel do not
/// share state.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// A scripted HTTP response.
    struct Response: Sendable {
        var status = 200
        var headers = ["Content-Type": "text/event-stream"]
        var chunks: [String] = []
        /// When `true`, the response never finishes; the client has to cancel it.
        var hangs = false
        /// When set, the load fails with this error before any response is sent.
        var failure: URLError?
        /// When `true`, nothing is sent at all; the client has to cancel the request.
        var stalls = false
    }

    /// The scripted responses of one host and a record of what the client did.
    final class Server: Sendable {
        private struct State {
            var responses: [Response]
            var requests: [URLRequest] = []
            var stoppedLoads = 0
        }

        let host = "stub-\(UUID().uuidString.lowercased()).test"
        /// Yields each time a request reaches the server.
        let arrivals: AsyncStream<Void>
        /// Yields each time the URL loading system stops a load (cancelled or completed).
        let stops: AsyncStream<Void>
        private let arrivalsContinuation: AsyncStream<Void>.Continuation
        private let stopsContinuation: AsyncStream<Void>.Continuation
        private let state: LockedState<State>

        init(_ responses: [Response]) {
            state = LockedState(State(responses: responses))
            (arrivals, arrivalsContinuation) = AsyncStream.makeStream(of: Void.self)
            (stops, stopsContinuation) = AsyncStream.makeStream(of: Void.self)
            StubURLProtocol.servers.withLock { $0[host] = self }
        }

        /// The URL to request.
        var url: URL {
            guard let url = URL(string: "https://\(host)/events") else {
                preconditionFailure("invalid stub URL")
            }
            return url
        }

        /// The requests received so far.
        var requests: [URLRequest] { state.withLock(\.requests) }

        /// How many loads were stopped by the URL loading system (cancelled or completed).
        var stoppedLoads: Int { state.withLock(\.stoppedLoads) }

        fileprivate func nextResponse(for request: URLRequest) -> Response? {
            defer { arrivalsContinuation.yield() }
            return state.withLock { state in
                state.requests.append(request)
                return state.responses.isEmpty ? nil : state.responses.removeFirst()
            }
        }

        fileprivate func recordStop() {
            state.withLock { $0.stoppedLoads += 1 }
            stopsContinuation.yield()
        }
    }

    fileprivate static let servers = LockedState<[String: Server]>([:])

    /// A session whose requests are served by this protocol.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private var server: Server?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let host = url.host,
            let server = Self.servers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        self.server = server
        guard let scripted = server.nextResponse(for: request),
            let response = HTTPURLResponse(
                url: url, statusCode: scripted.status, httpVersion: "HTTP/1.1",
                headerFields: scripted.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let failure = scripted.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        if scripted.stalls {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in scripted.chunks {
            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        }
        if !scripted.hangs {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        server?.recordStop()
    }
}
#endif
