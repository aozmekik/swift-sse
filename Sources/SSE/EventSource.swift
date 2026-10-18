import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Server-Sent Events client: an asynchronous sequence of the events of a `text/event-stream`.
///
/// `EventSource` follows the processing model of the WHATWG HTML Living Standard, section 9.2.3,
/// adapted to Swift Concurrency:
///
/// ```swift
/// let events = EventSource(url: URL(string: "https://example.com/updates")!)
/// for try await event in events {
///     print(event.type, event.data)
/// }
/// ```
///
/// Each iterator owns its own connection, which it opens lazily on the first call to `next()`.
/// The sequence is pull-based: the body is parsed only while you wait for the next event, and
/// when the connection ends a reconnection is attempted only when you ask for another event.
/// The transport reads a bounded amount ahead of you (`URLSession`'s own read-ahead on Apple
/// platforms; at most about 1 MiB on Linux, where the client suspends the request above that),
/// so a slow consumer slows the server down through TCP flow control instead of growing memory.
/// Breaking out of the loop closes the connection, and cancelling the iterating task cancels the
/// request and makes `next()` throw `CancellationError`.
///
/// ### Requests
///
/// Every request carries `Accept: text/event-stream`, `Cache-Control: no-cache` and
/// `Pragma: no-cache`, each unless the request sets that header itself, as the standard's fetch
/// with the cache mode "no-store" does. It bypasses the local cache, and its response is not
/// stored in the session's `URLCache`. When the last event ID string is not empty, the request
/// carries it in a `Last-Event-ID` header. Any method and body can be used, so the same type
/// serves `GET` event streams and `POST` endpoints of LLM APIs.
///
/// ### Responses
///
/// - 200 OK with `Content-Type: text/event-stream` (parameters ignored) is parsed as an event
///   stream.
/// - 204 No Content ends iteration normally; the standard defines it as the server's way of
///   telling clients to stop reconnecting.
/// - Any other status throws ``EventSourceError/unexpectedStatusCode(_:response:body:)``, and any
///   other content type throws ``EventSourceError/unexpectedContentType(_:response:body:)``.
///   Neither is retried.
///
/// ### Reconnection
///
/// When the stream ends or a network error occurs, the ``ReconnectionPolicy`` decides whether and
/// when to reconnect. The default depends on the request method: `GET` requests reconnect with
/// ``ReconnectionPolicy/default``; requests with any other method (typically `POST` requests to
/// LLM APIs, which must not be replayed) use ``ReconnectionPolicy/disabled``. Errors that a
/// reconnection cannot fix, such as an unsupported URL or an untrusted server certificate,
/// throw ``EventSourceError/connectionFailed(underlying:)`` at once, whatever the policy.
///
/// ### Platforms
///
/// On Apple platforms the client reads the body with `URLSession.bytes(for:)` on the session you
/// pass. On Linux it uses FoundationNetworking's `URLSessionDataDelegate`, with a session created
/// from your session's configuration.
public struct EventSource: AsyncSequence, Sendable {
    /// The events of the stream.
    public typealias Element = ServerSentEvent

    /// The request sent for every connection, before the headers that the client adds.
    public let request: URLRequest

    /// The policy that decides whether and when to reconnect.
    public let reconnectionPolicy: ReconnectionPolicy

    /// The last event ID string that the first connection starts from.
    public let initialLastEventID: String

    let environment: Environment

    /// Creates an event source for a request.
    ///
    /// - Parameters:
    ///   - request: The request to send for every connection. Its method, body and headers are
    ///     sent as is.
    ///   - session: The URL session to use. Defaults to `URLSession.shared`. Configure idle
    ///     timeouts through `request.timeoutInterval` or the session configuration: a stream that
    ///     is silent for longer than the timeout fails with `URLError.timedOut`, which counts as a
    ///     network error. Not asking for events for longer than the timeout while the transport's
    ///     buffer is full can also end in `URLError.timedOut`.
    ///   - reconnection: The reconnection policy, or `nil` (the default) to reconnect `GET`
    ///     requests with ``ReconnectionPolicy/default`` and never reconnect other methods.
    ///   - lastEventID: The initial last event ID string, for resuming a stream across app
    ///     launches. Defaults to the empty string (no `Last-Event-ID` header).
    public init(
        request: URLRequest,
        session: URLSession = .shared,
        reconnection: ReconnectionPolicy? = nil,
        lastEventID: String = ""
    ) {
        self.init(
            request: request,
            reconnection: reconnection,
            lastEventID: lastEventID,
            environment: .live(session: session)
        )
    }

    /// Creates an event source that sends `GET` requests to a URL.
    ///
    /// - Parameters:
    ///   - url: The URL of the event stream.
    ///   - session: The URL session to use. Defaults to `URLSession.shared`.
    ///   - reconnection: The reconnection policy. Defaults to ``ReconnectionPolicy/default``.
    ///   - lastEventID: The initial last event ID string. Defaults to the empty string.
    public init(
        url: URL,
        session: URLSession = .shared,
        reconnection: ReconnectionPolicy = .default,
        lastEventID: String = ""
    ) {
        self.init(
            request: URLRequest(url: url),
            session: session,
            reconnection: reconnection,
            lastEventID: lastEventID
        )
    }

    init(
        request: URLRequest,
        reconnection: ReconnectionPolicy?,
        lastEventID: String,
        environment: Environment
    ) {
        self.request = request
        self.reconnectionPolicy = reconnection ?? Self.defaultPolicy(for: request)
        self.initialLastEventID = lastEventID
        self.environment = environment
    }

    /// Creates an iterator with its own connection.
    ///
    /// - Returns: An iterator that connects on its first call to `next()`.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: self)
    }

    static func defaultPolicy(for request: URLRequest) -> ReconnectionPolicy {
        let method = request.httpMethod?.uppercased() ?? "GET"
        return method == "GET" ? .default : .disabled
    }

    /// Whether reconnecting cannot fix `error`, so that the event source fails at once instead
    /// of retrying forever.
    ///
    /// The standard lets a client fail the connection instead of reestablishing it when it
    /// "knows that to be futile" (section 9.2.3). These are failures that another attempt with
    /// the same request and session cannot change: the URL cannot be loaded at all, App
    /// Transport Security blocks it, the server's certificate is not trusted or a client
    /// certificate is missing or rejected, authentication was cancelled or is required, a file
    /// URL failed, or the URL loading system cancelled the load although the iterating task was
    /// not cancelled (an invalidated session, or a delegate that cancelled an authentication
    /// challenge).
    static func isPermanentFailure(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection,
            .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired,
            .userCancelledAuthentication, .userAuthenticationRequired,
            .fileDoesNotExist, .fileIsDirectory, .noPermissionsToReadFile,
            .cancelled:
            return true
        default:
            return false
        }
    }

    /// The `Last-Event-ID` header value that puts `lastEventID`, encoded as UTF-8, on the wire,
    /// as section 9.2.4 requires.
    ///
    /// CFNetwork, which both Apple transports use, serializes header values as ISO-8859-1 and
    /// truncates them at the first character that ISO-8859-1 cannot represent, so `café…` would
    /// be sent as the bytes of `caf` and a Latin-1 `é`. Spelling every UTF-8 byte as the
    /// ISO-8859-1 character with the same value makes it send exactly the UTF-8 bytes.
    /// FoundationNetworking hands header strings to libcurl as UTF-8, so there the ID is used
    /// as is.
    static func lastEventIDHeaderValue(_ lastEventID: String) -> String {
        #if canImport(FoundationNetworking)
        return lastEventID
        #else
        return String(String.UnicodeScalarView(lastEventID.utf8.map { Unicode.Scalar($0) }))
        #endif
    }
}

// MARK: - Environment

extension EventSource {
    /// The effects an event source performs, injectable for deterministic tests.
    struct Environment: Sendable {
        /// Opens connections.
        var transport: any EventStreamTransport
        /// Waits before a reconnection attempt; must throw when the task is cancelled.
        var sleep: @Sendable (Duration) async throws -> Void
        /// Returns a uniformly distributed number in `[0, 1)` for jitter.
        var random: @Sendable () -> Double
        /// How long the body of an error response is read for ``EventSourceError``.
        var errorBodyTimeout: Duration = .seconds(1)

        static func live(session: URLSession) -> Environment {
            #if canImport(FoundationNetworking)
            let transport = URLSessionDelegateTransport(session: session)
            #else
            let transport = URLSessionBytesTransport(session: session)
            #endif
            return Environment(
                transport: transport,
                sleep: { duration in try await Task.sleep(for: duration) },
                random: { Double.random(in: 0..<1) }
            )
        }
    }
}

// MARK: - Iterator

extension EventSource {
    /// The iterator of an ``EventSource``; it owns one connection at a time.
    ///
    /// After `next()` throws or returns `nil`, every later call returns `nil`.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private enum Phase {
            case idle
            case streaming(ResponseBodyReader)
            case reconnecting
            case finished
        }

        /// The largest error body kept in ``EventSourceError`` values.
        static let errorBodyLimit = 64 * 1024

        private let source: EventSource
        private var phase = Phase.idle
        private var parser: EventStreamParser
        private var connection: ConnectionLifetime?
        private var buffered: [ServerSentEvent] = []
        private var bufferedIndex = 0
        /// An error to throw once the already parsed events have been delivered.
        private var deferredError: (any Error)?
        /// The number of consecutive failed connections.
        ///
        /// Attempts that failed and connections that ended without delivering a single byte of
        /// body count; a connection that delivers data resets it.
        private var attempt = 0

        init(source: EventSource) {
            self.source = source
            self.parser = EventStreamParser(lastEventID: source.initialLastEventID)
        }

        /// Returns the next event, connecting or reconnecting as needed.
        ///
        /// - Returns: The next event, or `nil` when the stream has ended for good.
        /// - Throws: An ``EventSourceError``, or `CancellationError` when the task is cancelled.
        public mutating func next() async throws -> ServerSentEvent? {
            while true {
                if bufferedIndex < buffered.count {
                    let event = buffered[bufferedIndex]
                    bufferedIndex += 1
                    return event
                }
                buffered.removeAll(keepingCapacity: true)
                bufferedIndex = 0

                if let error = deferredError {
                    deferredError = nil
                    finish()
                    throw error
                }

                do {
                    switch phase {
                    case .finished:
                        return nil
                    case .idle:
                        try await connect()
                    case .reconnecting:
                        try await waitBeforeReconnecting()
                        try await connect()
                    case .streaming(let reader):
                        try await read(from: reader)
                    }
                } catch {
                    finish()
                    throw Self.isCancellation(error) ? CancellationError() : error
                }
            }
        }

        private mutating func connect() async throws {
            try Task.checkCancellation()
            let opened: EventStreamConnection
            do {
                opened = try await source.environment.transport.connect(prepareRequest())
            } catch {
                if Self.isCancellation(error) {
                    throw CancellationError()
                }
                connectionEnded(error: error)
                return
            }

            let lifetime = ConnectionLifetime(cancel: opened.cancel)
            guard let response = opened.response as? HTTPURLResponse else {
                lifetime.close()
                throw EventSourceError.notHTTPResponse(opened.response)
            }
            var reader = ResponseBodyReader(opened.body)

            if response.statusCode == 204 {
                lifetime.close()
                finish()
                return
            }
            guard response.statusCode == 200 else {
                let body = await readErrorBody(from: &reader, closing: lifetime)
                lifetime.close()
                throw EventSourceError.unexpectedStatusCode(
                    response.statusCode, response: response, body: body)
            }
            let contentType = response.value(forHTTPHeaderField: "Content-Type")
            guard MediaType.isEventStream(contentType) else {
                let body = await readErrorBody(from: &reader, closing: lifetime)
                lifetime.close()
                throw EventSourceError.unexpectedContentType(
                    contentType, response: response, body: body)
            }

            connection = lifetime
            phase = .streaming(reader)
        }

        /// Reads the start of an error response's body, for at most ``errorBodyLimit`` bytes and
        /// ``Environment/errorBodyTimeout``.
        ///
        /// A wrong-type response that keeps streaming (an NDJSON endpoint, a misconfigured
        /// proxy) or an error body that stalls must not hold back the error, so when the time is
        /// up the connection is closed, which ends the read with whatever has arrived.
        private func readErrorBody(
            from reader: inout ResponseBodyReader,
            closing connection: ConnectionLifetime
        ) async -> Data {
            let timeout = source.environment.errorBodyTimeout
            return await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        connection.close()
                    } catch {
                        // Cancelled: the body was read in time.
                    }
                }
                let body = await reader.readPrefix(limit: Self.errorBodyLimit)
                group.cancelAll()
                return body
            }
        }

        private mutating func read(from reader: ResponseBodyReader) async throws {
            var reader = reader
            let isOpen: Bool
            do {
                isOpen = try await reader.read(into: &parser, events: &buffered)
            } catch {
                if Self.isCancellation(error) {
                    throw CancellationError()
                }
                resetBackoffIfDataArrived(reader)
                connectionEnded(error: error)
                return
            }
            resetBackoffIfDataArrived(reader)
            if isOpen {
                phase = .streaming(reader)
            } else {
                connectionEnded(error: nil)
            }
        }

        /// A connection that delivered any data, events or only comments such as the keep-alive
        /// comments that section 9.2.7 recommends, was a working connection: the next
        /// reconnection starts again from the floor delay.
        private mutating func resetBackoffIfDataArrived(_ reader: ResponseBodyReader) {
            if reader.hasReceivedBytes {
                attempt = 0
            }
        }

        /// Handles the end of a connection.
        ///
        /// `error` is `nil` when the server closed the stream. Errors are deferred until the
        /// events parsed so far are delivered.
        private mutating func connectionEnded(error: (any Error)?) {
            closeConnection()
            if let error,
                !source.reconnectionPolicy.isEnabled || EventSource.isPermanentFailure(error)
            {
                deferredError = EventSourceError.connectionFailed(underlying: error)
                return
            }
            guard source.reconnectionPolicy.isEnabled else {
                phase = .finished
                return
            }
            attempt += 1
            if let limit = source.reconnectionPolicy.maximumAttempts, attempt > limit {
                deferredError = EventSourceError.reconnectionLimitReached(
                    attempts: limit, lastError: error)
                return
            }
            phase = .reconnecting
        }

        private mutating func waitBeforeReconnecting() async throws {
            let delay = source.reconnectionPolicy.delay(
                beforeAttempt: attempt,
                serverReconnectionTime: parser.reconnectionTime,
                randomValue: source.environment.random()
            )
            try await source.environment.sleep(delay)
        }

        private func prepareRequest() -> URLRequest {
            var request = source.request
            // Section 9.2.2 fetches with the cache mode "no-store", for which Fetch adds
            // `Pragma: no-cache` and `Cache-Control: no-cache` unless the request has them.
            let defaults = [
                ("Accept", "text/event-stream"),
                ("Cache-Control", "no-cache"),
                ("Pragma", "no-cache"),
            ]
            for (field, value) in defaults where request.value(forHTTPHeaderField: field) == nil {
                request.setValue(value, forHTTPHeaderField: field)
            }
            let lastEventID = parser.lastEventID
            request.setValue(
                lastEventID.isEmpty ? nil : EventSource.lastEventIDHeaderValue(lastEventID),
                forHTTPHeaderField: "Last-Event-ID")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        }

        private mutating func closeConnection() {
            parser.finish()
            connection?.close()
            connection = nil
        }

        private mutating func finish() {
            closeConnection()
            phase = .finished
        }

        private static func isCancellation(_ error: any Error) -> Bool {
            if error is CancellationError {
                return true
            }
            // URLSession reports cancellation as URLError.cancelled; once the task is cancelled,
            // any failure is a consequence of the cancellation.
            return Task.isCancelled
        }
    }
}
