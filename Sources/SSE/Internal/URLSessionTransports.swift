import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if !canImport(FoundationNetworking)
/// The default transport on Apple platforms: `URLSession.bytes(for:)`.
///
/// It uses the caller's session as is, including its delegate (authentication challenges,
/// metrics) and its configuration. A task delegate keeps responses out of the session's
/// `URLCache`; every other delegate message still goes to the session's delegate.
struct URLSessionBytesTransport: EventStreamTransport {
    let session: URLSession

    func connect(_ request: URLRequest) async throws -> EventStreamConnection {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoStoreDelegate())
        let task = bytes.task
        return EventStreamConnection(response: response, body: .bytes(bytes)) {
            task.cancel()
        }
    }
}

/// A task delegate that only declines to store the response in the cache.
///
/// Section 9.2.2 fetches with the cache mode "no-store". `URLSession` stores a completed `GET`
/// response in the session's `URLCache` even when the request ignores cached data, so an event
/// stream (which can contain anything the server pushed) would end up in the cache.
final class NoStoreDelegate: NSObject, URLSessionDataDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
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
        let body = ResponseBody.chunks(delegate.body) { [delegate] count in
            delegate.didConsume(count)
        }
        return EventStreamConnection(response: response, body: body) {
            task.cancel()
        }
    }
}

/// Bridges `URLSessionDataDelegate` callbacks to async code.
///
/// The response head resumes the continuation passed to ``start(_:)``; body chunks are yielded
/// to ``body``; completion finishes ``body`` and invalidates the session, which releases this
/// delegate. Responses are never stored in the session's cache.
///
/// `URLSession` pushes body chunks as fast as the network delivers them, so the delegate applies
/// flow control: when more than ``highWaterMark`` bytes have been received but not consumed
/// (see ``didConsume(_:)``), it suspends the task, which stops reading from the socket and lets
/// TCP flow control slow the server down; it resumes the task once the reader has drained the
/// buffer to ``lowWaterMark``. On Linux it does not (see ``suspendsTasks``).
final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, Sendable {
    /// Whether the delegate suspends the task when the buffer is full.
    ///
    /// Off on Linux: swift-corelibs-foundation keeps reading after `suspend()`, so it does not
    /// bound the buffer, and with Swift 6.4 a later `resume()` restarted the transfer, replaying
    /// the stream from its first event. Delivering every event once matters more than the bound.
    #if canImport(FoundationNetworking)
    static let suspendsTasks = false
    #else
    static let suspendsTasks = true
    #endif

    /// The buffered byte count above which the task is suspended.
    static let highWaterMark = 1 << 20
    /// The buffered byte count at or below which a suspended task is resumed.
    static let lowWaterMark = 256 << 10

    /// The response body.
    ///
    /// Terminating it (or dropping its last iterator) cancels the task.
    let body: AsyncThrowingStream<Data, any Error>

    private struct FlowControl {
        var task: URLSessionDataTask?
        var bufferedBytes = 0
        var isSuspended = false
    }

    private let bodyContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let pendingResponse = LockedState<CheckedContinuation<URLResponse, any Error>?>(nil)
    private let flowControl = LockedState(FlowControl())
    /// Serializes `suspend()` and `resume()` calls in the order the flow control decided them,
    /// without calling into `URLSession` while holding the lock.
    private let taskControl = DispatchQueue(label: "tr.fergani.swift-sse.flow-control")

    override init() {
        (body, bodyContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        super.init()
    }

    /// Starts `task` and waits for its response head.
    func start(_ task: URLSessionDataTask) async throws -> URLResponse {
        bodyContinuation.onTermination = { _ in
            task.cancel()
        }
        flowControl.withLock { $0.task = task }
        return try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            pendingResponse.withLock { $0 = continuation }
            task.resume()
        }
    }

    /// Records that the reader has consumed `count` bytes of ``body``, resuming a suspended task
    /// once the buffer has drained to ``lowWaterMark``.
    func didConsume(_ count: Int) {
        flowControl.withLock { flow in
            flow.bufferedBytes -= count
            guard flow.isSuspended, flow.bufferedBytes <= Self.lowWaterMark, let task = flow.task
            else { return }
            flow.isSuspended = false
            taskControl.async { task.resume() }
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
        flowControl.withLock { flow in
            flow.bufferedBytes += data.count
            guard Self.suspendsTasks, !flow.isSuspended, flow.bufferedBytes > Self.highWaterMark
            else { return }
            flow.isSuspended = true
            taskControl.async { dataTask.suspend() }
        }
        bodyContinuation.yield(data)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        // Section 9.2.2 fetches with the cache mode "no-store".
        completionHandler(nil)
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
