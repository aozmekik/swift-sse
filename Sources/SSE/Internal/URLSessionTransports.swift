import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if !canImport(FoundationNetworking)
/// The default transport on Apple platforms: `URLSession.bytes(for:)`.
///
/// It uses the caller's session as is, including its delegate (authentication challenges,
/// metrics) and its configuration.
struct URLSessionBytesTransport: EventStreamTransport {
    let session: URLSession

    func connect(_ request: URLRequest) async throws -> EventStreamConnection {
        let (bytes, response) = try await session.bytes(for: request)
        let task = bytes.task
        return EventStreamConnection(response: response, body: .bytes(bytes)) {
            task.cancel()
        }
    }
}
#endif

/// A portable transport built on `URLSessionDataDelegate`.
///
/// This is the default on Linux, where FoundationNetworking has no `URLSession.bytes(for:)`. Each
/// connection uses a short-lived session created from the caller's session's *configuration*; the
/// caller's session delegate is not consulted. It also builds and runs on Apple platforms, where
/// the test suite exercises it next to ``URLSessionBytesTransport``.
struct URLSessionDelegateTransport: EventStreamTransport {
    let session: URLSession

    func connect(_ request: URLRequest) async throws -> EventStreamConnection {
        let delegate = StreamingDataDelegate()
        let streamingSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = streamingSession.dataTask(with: request)
        let response = try await withTaskCancellationHandler {
            try await delegate.start(task)
        } onCancel: {
            task.cancel()
        }
        return EventStreamConnection(response: response, body: .chunks(delegate.body)) {
            task.cancel()
        }
    }
}

/// Bridges `URLSessionDataDelegate` callbacks to async code.
///
/// The response head resumes the continuation passed to ``start(_:)``; body chunks are yielded
/// to ``body``; completion finishes ``body`` and invalidates the session, which releases this
/// delegate.
final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// The response body.
    ///
    /// Terminating it (or dropping its last iterator) cancels the task.
    let body: AsyncThrowingStream<Data, any Error>

    private let bodyContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let pendingResponse = LockedState<CheckedContinuation<URLResponse, any Error>?>(nil)

    override init() {
        (body, bodyContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        super.init()
    }

    /// Starts `task` and waits for its response head.
    func start(_ task: URLSessionDataTask) async throws -> URLResponse {
        bodyContinuation.onTermination = { _ in
            task.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            pendingResponse.withLock { $0 = continuation }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        takePendingResponse()?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodyContinuation.yield(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let continuation = takePendingResponse() {
            if let error {
                continuation.resume(throwing: error)
            } else if let response = task.response {
                continuation.resume(returning: response)
            } else {
                continuation.resume(throwing: URLError(.badServerResponse))
            }
        }
        if let error {
            bodyContinuation.finish(throwing: error)
        } else {
            bodyContinuation.finish()
        }
        session.finishTasksAndInvalidate()
    }

    private func takePendingResponse() -> CheckedContinuation<URLResponse, any Error>? {
        pendingResponse.withLock { pending in
            defer { pending = nil }
            return pending
        }
    }
}
