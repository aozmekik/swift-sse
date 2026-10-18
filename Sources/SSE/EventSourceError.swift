import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An error that ends iteration of an ``EventSource``.
///
/// Cancelling the task that iterates an event source is not reported with this type: iteration
/// throws `CancellationError` instead.
public enum EventSourceError: Error, Sendable {
    /// The server answered with a status code other than 200 OK.
    ///
    /// As the standard requires ("fail the connection"), this is not retried. A `204 No Content`
    /// response is not an error: it ends iteration normally, because the standard defines it as the
    /// server's way of telling the client to stop reconnecting.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code.
    ///   - response: The full response, for headers such as `Retry-After`.
    ///   - body: The start of the response body (at most 64 KiB), which for LLM APIs usually
    ///     contains a JSON error description.
    case unexpectedStatusCode(Int, response: HTTPURLResponse, body: Data)

    /// The server answered 200 OK with a `Content-Type` other than `text/event-stream`.
    ///
    /// MIME type parameters such as `charset` are ignored. This is not retried.
    ///
    /// - Parameters:
    ///   - contentType: The `Content-Type` header, or `nil` if the response had none.
    ///   - response: The full response.
    ///   - body: The start of the response body (at most 64 KiB).
    case unexpectedContentType(String?, response: HTTPURLResponse, body: Data)

    /// The response was not an HTTP response, for example because the URL was not `http(s)`.
    ///
    /// - Parameter response: The response that was received.
    case notHTTPResponse(URLResponse)

    /// The connection failed and the event source does not reconnect.
    ///
    /// Either the reconnection policy is ``ReconnectionPolicy/disabled``, or the error is one that
    /// reconnecting cannot fix, such as an unsupported URL or an untrusted server certificate;
    /// ``ReconnectionPolicy`` lists them.
    ///
    /// - Parameter underlying: The transport error, typically a `URLError`.
    case connectionFailed(underlying: any Error)

    /// The reconnection policy's ``ReconnectionPolicy/maximumAttempts`` were used up by
    /// consecutive attempts that failed or delivered no data.
    ///
    /// - Parameters:
    ///   - attempts: The number of consecutive reconnection attempts that were made.
    ///   - lastError: The error that ended the last attempt, or `nil` if the server closed the
    ///     stream without sending an event.
    case reconnectionLimitReached(attempts: Int, lastError: (any Error)?)
}

extension EventSourceError: CustomStringConvertible {
    /// A human-readable description of the error, including the start of an error body.
    public var description: String {
        switch self {
        case .unexpectedStatusCode(let statusCode, _, let body):
            return "Unexpected HTTP status \(statusCode)\(Self.bodySuffix(body))"
        case .unexpectedContentType(let contentType, _, let body):
            let received = contentType.map { "'\($0)'" } ?? "no Content-Type header"
            return "Expected Content-Type text/event-stream, got \(received)"
                + Self.bodySuffix(body)
        case .notHTTPResponse(let response):
            let url = response.url?.absoluteString ?? "an unknown URL"
            return "Expected an HTTP response from \(url)"
        case .connectionFailed(let underlying):
            return "Connection failed: \(underlying)"
        case .reconnectionLimitReached(let attempts, let lastError):
            let cause = lastError.map { ": \($0)" } ?? " (the server closed the stream)"
            return "Gave up after \(attempts) reconnection attempts without data\(cause)"
        }
    }

    private static func bodySuffix(_ body: Data) -> String {
        guard !body.isEmpty else { return "" }
        let text = String(decoding: body.prefix(512), as: UTF8.self)
        return ": \(text)"
    }
}

extension EventSourceError: LocalizedError {
    /// The same text as ``description``, for APIs that display `localizedDescription`.
    public var errorDescription: String? { description }
}
