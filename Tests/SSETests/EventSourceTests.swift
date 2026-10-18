import Foundation
import Testing

@testable import SSE

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client behaviour with a scripted transport and an injected sleeper: no network, no real time.
@Suite("EventSource")
struct EventSourceTests {
    // MARK: Requests and events

    @Test("Events are delivered across chunks and the first request is prepared")
    func deliversEvents() async throws {
        let transport = StubTransport([
            .stream("data: one\n", "\ndata: tw", "o\n\nevent: custom\ndata: 3\n\n")
        ])
        let (events, error) = await collect(.stubbed(transport, reconnection: .disabled))

        #expect(error == nil)
        #expect(
            events == [
                ServerSentEvent(data: "one"),
                ServerSentEvent(data: "two"),
                ServerSentEvent(type: "custom", data: "3"),
            ])
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        #expect(request.sentLastEventID == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("The caller's method, body and Accept, Cache-Control and Pragma headers are kept")
    func keepsCallerRequest() async throws {
        let transport = StubTransport([.stream("data: x\n\n")])
        var request = URLRequest(url: testURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("private", forHTTPHeaderField: "Pragma")
        let source = EventSource(
            request: request,
            reconnection: nil,
            lastEventID: "",
            environment: .init(transport: transport, sleep: { _ in }, random: { 0 })
        )
        _ = await collect(source)

        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.httpBody == Data("{}".utf8))
        #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream, application/json")
        #expect(sent.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(sent.value(forHTTPHeaderField: "Pragma") == "private")
    }

    @Test("An initial last event ID is sent with the first request")
    func initialLastEventID() async throws {
        let transport = StubTransport([.stream("data: x\n\n")])
        let (events, _) = await collect(
            .stubbed(transport, reconnection: .disabled, lastEventID: "41"))

        #expect(transport.requests.first?.sentLastEventID == "41")
        #expect(events.first?.lastEventID == "41")
    }

    // MARK: Reconnection

    @Test("After the stream ends, it reconnects with Last-Event-ID after the server's retry time")
    func reconnectsWithLastEventID() async throws {
        let transport = StubTransport([
            .stream("retry: 1500\nid: 7\ndata: a\n\n"),
            .stream("id: 8\ndata: b\n\n"),
        ])
        let sleeper = RecordingSleeper()
        let (events, _) = await collect(.stubbed(transport, sleeper: sleeper), limit: 2)

        #expect(events.map(\.data) == ["a", "b"])
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].sentLastEventID == "7")
        #expect(sleeper.recorded == [.milliseconds(1500)])
    }

    @Test("The last event ID persists across reconnections whose streams carry no id")
    func lastEventIDPersistsAcrossReconnection() async throws {
        let transport = StubTransport([
            .stream("id: \u{2026}\nretry: 200\ndata: hello\n\n"),
            .stream("data: again\n\n"),
            .stream("data: third\n\n"),
        ])
        let (events, _) = await collect(.stubbed(transport), limit: 3)

        #expect(events.map(\.lastEventID) == ["\u{2026}", "\u{2026}", "\u{2026}"])
        let headers = transport.requests.map(\.sentLastEventID)
        #expect(headers == [nil, "\u{2026}", "\u{2026}"])
    }

    @Test("An id in an unterminated block is not sent (WPT format-data-before-final-empty-line)")
    func unterminatedIDIsNotSent() async throws {
        let transport = StubTransport([
            .stream("retry:1000\ndata:test1\n\nid:test\ndata:test2"),
            .stream("data:test1\n\n"),
        ])
        let (events, _) = await collect(.stubbed(transport), limit: 2)

        #expect(events.map(\.lastEventID) == ["", ""])
        #expect(transport.requests[1].sentLastEventID == nil)
    }

    @Test("Consecutive failures back off exponentially and an event resets the backoff")
    func exponentialBackoff() async throws {
        let refused = URLError(.cannotConnectToHost)
        let transport = StubTransport([
            .connectFails(refused),
            .connectFails(refused),
            .connectFails(refused),
            .stream("data: up\n\n"),
            .stream("data: again\n\n"),
        ])
        let sleeper = RecordingSleeper()
        let (events, error) = await collect(.stubbed(transport, sleeper: sleeper), limit: 2)

        #expect(error == nil)
        #expect(events.map(\.data) == ["up", "again"])
        #expect(sleeper.recorded == [.seconds(3), .seconds(6), .seconds(12), .seconds(3)])
    }

    @Test("A connection that closes without sending anything counts as a failed attempt")
    func emptyConnectionsBackOff() async throws {
        let transport = StubTransport([
            .stream(""),
            .stream(""),
            .stream("data: finally\n\n"),
        ])
        let sleeper = RecordingSleeper()
        _ = await collect(.stubbed(transport, sleeper: sleeper), limit: 1)

        #expect(sleeper.recorded == [.seconds(3), .seconds(6)])
    }

    @Test("Connections that only send keep-alive comments do not back off or use up attempts")
    func heartbeatsResetBackoff() async throws {
        let heartbeats = Array(
            repeating: Script.stream(": keep-alive\n", ": keep-alive\n"), count: 12)
        let transport = StubTransport(heartbeats + [.stream("data: news\n\n")])
        let sleeper = RecordingSleeper()
        let policy = ReconnectionPolicy.exponentialBackoff(
            reconnectionTime: .seconds(1), maximumDelay: .seconds(30), maximumAttempts: 10)
        let (events, error) = await collect(
            .stubbed(transport, reconnection: policy, sleeper: sleeper), limit: 1)

        #expect(error == nil)
        #expect(events.map(\.data) == ["news"])
        #expect(sleeper.recorded == Array(repeating: .seconds(1), count: 12))
    }

    @Test("Data received before a network error resets the backoff")
    func dataBeforeErrorResetsBackoff() async throws {
        let refused = URLError(.cannotConnectToHost)
        let transport = StubTransport([
            .connectFails(refused),
            .connectFails(refused),
            .stream(": hello\n", end: .fail(URLError(.networkConnectionLost))),
            .stream("data: up\n\n"),
        ])
        let sleeper = RecordingSleeper()
        _ = await collect(.stubbed(transport, sleeper: sleeper), limit: 1)

        #expect(sleeper.recorded == [.seconds(3), .seconds(6), .seconds(3)])
    }

    @Test("A network error mid-stream reconnects after the events already received")
    func reconnectsAfterNetworkError() async throws {
        let transport = StubTransport([
            .stream("id: 1\ndata: a\n\ndata: b\n\n", end: .fail(URLError(.networkConnectionLost))),
            .stream("data: c\n\n"),
        ])
        let (events, error) = await collect(.stubbed(transport), limit: 3)

        #expect(error == nil)
        #expect(events.map(\.data) == ["a", "b", "c"])
        #expect(transport.requests[1].sentLastEventID == "1")
    }

    @Test("Jitter extends the delay by the configured fraction")
    func jitter() async throws {
        let transport = StubTransport([
            .connectFails(URLError(.timedOut)),
            .stream("data: x\n\n"),
        ])
        let sleeper = RecordingSleeper()
        _ = await collect(.stubbed(transport, sleeper: sleeper, random: 0.5), limit: 1)

        // 3 s × (1 + 0.5 × 0.5)
        #expect(sleeper.recorded == [.seconds(3.75)])
    }

    @Test("A server that sends retry: 0 cannot cause a tight loop after failures")
    func zeroRetryStillBacksOff() async throws {
        let transport = StubTransport([
            .stream("retry: 0\ndata: a\n\n"),
            .connectFails(URLError(.cannotConnectToHost)),
            .stream("data: b\n\n"),
        ])
        let sleeper = RecordingSleeper()
        _ = await collect(.stubbed(transport, sleeper: sleeper), limit: 2)

        #expect(sleeper.recorded == [.zero, .seconds(6)])
    }

    @Test("Giving up after the maximum number of attempts reports the last error")
    func maximumAttempts() async throws {
        let refused = URLError(.cannotConnectToHost)
        let transport = StubTransport([
            .connectFails(refused), .connectFails(refused), .connectFails(refused),
        ])
        let policy = ReconnectionPolicy.exponentialBackoff(maximumAttempts: 2)
        let (events, error) = await collect(.stubbed(transport, reconnection: policy))

        #expect(events.isEmpty)
        #expect(transport.requests.count == 3)
        guard
            case .reconnectionLimitReached(let attempts, let lastError)? = error
                as? EventSourceError
        else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(attempts == 2)
        #expect((lastError as? URLError)?.code == .cannotConnectToHost)
    }

    @Test("Giving up after streams that close without events has no last error")
    func maximumAttemptsWithoutErrors() async throws {
        let transport = StubTransport([.stream(""), .stream("")])
        let policy = ReconnectionPolicy.exponentialBackoff(maximumAttempts: 1)
        let (_, error) = await collect(.stubbed(transport, reconnection: policy))

        guard case .reconnectionLimitReached(1, let lastError)? = error as? EventSourceError else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(lastError == nil)
    }

    // MARK: Errors that reconnecting cannot fix

    @Test(
        "Errors that reconnecting cannot fix fail at once, whatever the policy",
        arguments: [
            URLError.Code.badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection,
            .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired,
            .userCancelledAuthentication, .userAuthenticationRequired,
            .fileDoesNotExist, .fileIsDirectory, .noPermissionsToReadFile, .cancelled,
        ]
    )
    func permanentFailuresAreNotRetried(code: URLError.Code) async throws {
        let transport = StubTransport([.connectFails(URLError(code))])
        let sleeper = RecordingSleeper()
        let (events, error) = await collect(.stubbed(transport, sleeper: sleeper))

        #expect(events.isEmpty)
        guard case .connectionFailed(let underlying)? = error as? EventSourceError else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect((underlying as? URLError)?.code == code)
        #expect(transport.requests.count == 1)
        #expect(sleeper.recorded.isEmpty)
    }

    @Test(
        "Transient network errors are retried",
        arguments: [
            URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
            .badServerResponse, .unknown,
        ]
    )
    func transientFailuresAreRetried(code: URLError.Code) async throws {
        let transport = StubTransport([.connectFails(URLError(code)), .stream("data: up\n\n")])
        let sleeper = RecordingSleeper()
        let (events, error) = await collect(.stubbed(transport, sleeper: sleeper), limit: 1)

        #expect(error == nil)
        #expect(events.map(\.data) == ["up"])
        #expect(sleeper.recorded == [.seconds(3)])
    }

    @Test("A permanent error mid-stream is thrown after the events already received")
    func permanentFailureMidStream() async throws {
        let transport = StubTransport([
            .stream("data: a\n\n", end: .fail(URLError(.userCancelledAuthentication)))
        ])
        let (events, error) = await collect(.stubbed(transport))

        #expect(events.map(\.data) == ["a"])
        guard case .connectionFailed(let underlying)? = error as? EventSourceError else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect((underlying as? URLError)?.code == .userCancelledAuthentication)
        #expect(transport.requests.count == 1)
    }

    // MARK: Disabled reconnection

    @Test("With reconnection disabled, the sequence ends when the server closes the stream")
    func disabledEndsAtClose() async throws {
        let transport = StubTransport([.stream("data: a\n\ndata: b\n\n")])
        let (events, error) = await collect(.stubbed(transport, reconnection: .disabled))

        #expect(events.map(\.data) == ["a", "b"])
        #expect(error == nil)
        #expect(transport.requests.count == 1)
    }

    @Test("With reconnection disabled, a network error is thrown after the events received")
    func disabledThrowsConnectionFailed() async throws {
        let transport = StubTransport([
            .stream("data: a\n\n", end: .fail(URLError(.networkConnectionLost)))
        ])
        let (events, error) = await collect(.stubbed(transport, reconnection: .disabled))

        #expect(events.map(\.data) == ["a"])
        guard case .connectionFailed(let underlying)? = error as? EventSourceError else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect((underlying as? URLError)?.code == .networkConnectionLost)
    }

    @Test("POST requests do not reconnect by default; GET requests do")
    func defaultPolicyDependsOnMethod() async throws {
        let post = StubTransport([.stream("data: a\n\n")])
        let (events, error) = await collect(.stubbed(post, method: "POST"))
        #expect(events.map(\.data) == ["a"])
        #expect(error == nil)
        #expect(post.requests.count == 1)

        #expect(EventSource.stubbed(post, method: "post").reconnectionPolicy == .disabled)
        #expect(EventSource.stubbed(post, method: "GET").reconnectionPolicy == .default)
        #expect(EventSource(url: testURL).reconnectionPolicy == .default)
    }

    // MARK: Response validation

    @Test("A non-200 status throws with the error body and is not retried")
    func unexpectedStatus() async throws {
        let transport = StubTransport([
            .respond(
                status: 429, contentType: "application/json",
                chunks: ["{\"error\":", "\"rate_limited\"}"], end: .close)
        ])
        let (_, error) = await collect(.stubbed(transport))

        guard case .unexpectedStatusCode(429, let response, let body)? = error as? EventSourceError
        else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(response.statusCode == 429)
        #expect(String(decoding: body, as: UTF8.self) == "{\"error\":\"rate_limited\"}")
        #expect(transport.requests.count == 1)
        #expect(transport.cancelledConnections == 1)
    }

    @Test(
        "Content types that are text/event-stream are accepted",
        arguments: [
            "text/event-stream", "text/event-stream;", "text/event-stream; charset=utf-8",
            "TEXT/Event-Stream", " text/event-stream ",
        ]
    )
    func acceptedContentTypes(contentType: String) async throws {
        let transport = StubTransport([
            .respond(status: 200, contentType: contentType, chunks: ["data: x\n\n"], end: .close)
        ])
        let (events, error) = await collect(.stubbed(transport, reconnection: .disabled))
        #expect(error == nil)
        #expect(events.count == 1)
    }

    @Test(
        "Other content types throw and are not retried",
        arguments: [
            "text/plain", "application/json", "x bogus", "text/x-bogus", "text/event-streams", "",
            nil,
        ] as [String?]
    )
    func rejectedContentTypes(contentType: String?) async throws {
        let transport = StubTransport([
            .respond(status: 200, contentType: contentType, chunks: ["data: x\n\n"], end: .close)
        ])
        let (events, error) = await collect(.stubbed(transport))

        #expect(events.isEmpty)
        guard case .unexpectedContentType(let received, _, let body)? = error as? EventSourceError
        else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(received == contentType)
        #expect(String(decoding: body, as: UTF8.self) == "data: x\n\n")
        #expect(transport.requests.count == 1)
    }

    @Test("204 No Content ends the sequence normally, also on a reconnection")
    func noContentStops() async throws {
        let transport = StubTransport([
            .stream("data: a\n\n"),
            .respond(status: 204, contentType: nil, chunks: [], end: .close),
        ])
        let (events, error) = await collect(.stubbed(transport))

        #expect(events.map(\.data) == ["a"])
        #expect(error == nil)
        #expect(transport.requests.count == 2)
    }

    @Test("A response that is not HTTP throws notHTTPResponse")
    func notHTTP() async throws {
        let transport = StubTransport([.nonHTTPResponse])
        let (_, error) = await collect(.stubbed(transport))
        guard case .notHTTPResponse(let response)? = error as? EventSourceError else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(response.url == testURL)
    }

    @Test("After an error the iterator returns nil")
    func finishedAfterError() async throws {
        let transport = StubTransport([
            .respond(status: 500, contentType: nil, chunks: [], end: .close)
        ])
        var iterator = EventSource.stubbed(transport).makeAsyncIterator()
        await #expect(throws: EventSourceError.self) { _ = try await iterator.next() }
        let next = try await iterator.next()
        #expect(next == nil)
    }

    // MARK: Cancellation

    @Test("Cancelling the task while it waits for data throws CancellationError and closes")
    func cancelWhileStreaming() async throws {
        let transport = StubTransport([.stream("data: first\n\n", end: .hang)])
        let source = EventSource.stubbed(transport)
        let (received, receivedContinuation) = AsyncStream.makeStream(of: ServerSentEvent.self)

        let task = Task {
            var events: [ServerSentEvent] = []
            for try await event in source {
                events.append(event)
                receivedContinuation.yield(event)
            }
            return events
        }
        for await _ in received { break }  // Wait for the first event, then cancel.
        task.cancel()

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(transport.cancelledConnections == 1)
        #expect(transport.requests.count == 1)
    }

    @Test("Cancelling the task during the reconnection delay throws CancellationError")
    func cancelWhileWaitingToReconnect() async throws {
        let transport = StubTransport([.connectFails(URLError(.cannotConnectToHost))])
        let sleeper = RecordingSleeper(blocksUntilCancelled: true)
        let source = EventSource.stubbed(transport, sleeper: sleeper)

        let task = Task { try await collectThrowing(source) }
        for await _ in sleeper.sleepStarted { break }
        task.cancel()

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(transport.requests.count == 1)
    }

    @Test("A cancelled task does not connect")
    func cancelledBeforeConnecting() async throws {
        let transport = StubTransport([.stream("data: x\n\n")])
        let source = EventSource.stubbed(transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await collectThrowing(source)
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(transport.requests.isEmpty)
    }

    @Test("Breaking out of the loop closes the connection")
    func breakClosesConnection() async throws {
        let transport = StubTransport([.stream("data: a\n\ndata: b\n\n", end: .hang)])
        let (events, error) = await collect(.stubbed(transport), limit: 1)

        #expect(events.map(\.data) == ["a"])
        #expect(error == nil)
        #expect(transport.cancelledConnections == 1)
    }
}

/// Collects all events, rethrowing errors.
private func collectThrowing(_ source: EventSource) async throws -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    for try await event in source {
        events.append(event)
    }
    return events
}
