import Foundation
import Testing

@testable import SSE

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Descriptions")
struct DescriptionTests {
    @Test("ServerSentEvent describes its fields")
    func eventDescription() {
        #expect(
            ServerSentEvent(data: "a\nb").description
                == #"ServerSentEvent(type: message, data: "a\nb")"#)
        #expect(
            ServerSentEvent(type: "ping", data: "", lastEventID: "7").description
                == #"ServerSentEvent(type: ping, lastEventID: 7, data: "")"#)
    }

    @Test("EventSourceError describes every case")
    func errorDescriptions() throws {
        let response = try #require(
            HTTPURLResponse(url: testURL, statusCode: 503, httpVersion: nil, headerFields: nil))
        let body = Data(#"{"error":"overloaded"}"#.utf8)
        let cases: [(EventSourceError, String)] = [
            (
                .unexpectedStatusCode(503, response: response, body: body),
                #"Unexpected HTTP status 503: {"error":"overloaded"}"#
            ),
            (
                .unexpectedStatusCode(503, response: response, body: Data()),
                "Unexpected HTTP status 503"
            ),
            (
                .unexpectedContentType("text/html", response: response, body: Data()),
                "Expected Content-Type text/event-stream, got 'text/html'"
            ),
            (
                .unexpectedContentType(nil, response: response, body: Data()),
                "Expected Content-Type text/event-stream, got no Content-Type header"
            ),
            (
                .notHTTPResponse(
                    URLResponse(
                        url: testURL, mimeType: nil, expectedContentLength: 0,
                        textEncodingName: nil)),
                "Expected an HTTP response from https://example.test/stream"
            ),
            (
                .reconnectionLimitReached(attempts: 3, lastError: nil),
                "Gave up after 3 reconnection attempts without an event (the server closed the stream)"
            ),
        ]
        for (error, expected) in cases {
            #expect(error.description == expected)
            #expect(error.errorDescription == expected)
        }
        let failed = EventSourceError.connectionFailed(underlying: URLError(.timedOut))
        #expect(failed.description.hasPrefix("Connection failed: "))
        let limited = EventSourceError.reconnectionLimitReached(
            attempts: 1, lastError: URLError(.timedOut))
        #expect(
            limited.description.hasPrefix(
                "Gave up after 1 reconnection attempts without an event: "))
    }
}
