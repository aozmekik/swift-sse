import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Opens the HTTP connections of an ``EventSource``.
///
/// The production transports wrap `URLSession`; tests substitute scripted transports.
protocol EventStreamTransport: Sendable {
    /// Sends `request` and returns once the response head has arrived.
    func connect(_ request: URLRequest) async throws -> EventStreamConnection
}

/// An open HTTP response whose body has not been consumed yet.
struct EventStreamConnection {
    /// The response head.
    var response: URLResponse
    /// The response body.
    var body: ResponseBody
    /// Cancels the underlying request.
    ///
    /// Must be safe to call repeatedly and after completion.
    var cancel: @Sendable () -> Void
}

/// The body of a response, in the shape the transport produces it.
enum ResponseBody {
    #if !canImport(FoundationNetworking)
    /// A byte sequence from `URLSession.bytes(for:)`.
    case bytes(URLSession.AsyncBytes)
    #endif
    /// A sequence of chunks, as delivered by `URLSessionDataDelegate` or by a test.
    case chunks(AsyncThrowingStream<Data, any Error>)
}

/// Cancels a connection when the last reference to it goes away.
///
/// The iterator of an ``EventSource`` holds one of these for its current connection, so that
/// abandoning the iterator (for example by breaking out of a `for try await` loop) closes the HTTP
/// connection instead of leaving it open until the server ends it.
final class ConnectionLifetime: Sendable {
    private let cancel: LockedState<(@Sendable () -> Void)?>

    init(cancel: @escaping @Sendable () -> Void) {
        self.cancel = LockedState(cancel)
    }

    /// Cancels the connection; later calls do nothing.
    func close() {
        let cancel = self.cancel.withLock { cancel in
            defer { cancel = nil }
            return cancel
        }
        cancel?()
    }

    deinit {
        close()
    }
}

/// Reads a ``ResponseBody`` into an ``EventStreamParser``.
struct ResponseBodyReader {
    private enum Source {
        #if !canImport(FoundationNetworking)
        case bytes(URLSession.AsyncBytes.AsyncIterator)
        #endif
        case chunks(AsyncThrowingStream<Data, any Error>.AsyncIterator)
    }

    /// Bytes are handed to the parser at line terminators or when this many have accumulated.
    private static let flushThreshold = 16 * 1024

    private var source: Source
    private var scratch: [UInt8] = []

    init(_ body: ResponseBody) {
        switch body {
        #if !canImport(FoundationNetworking)
        case .bytes(let bytes):
            source = .bytes(bytes.makeAsyncIterator())
        #endif
        case .chunks(let chunks):
            source = .chunks(chunks.makeAsyncIterator())
        }
    }

    /// Reads until the parser dispatches at least one event or the body ends.
    ///
    /// Events are appended to `events`. When this method throws, it has not appended any event.
    ///
    /// - Returns: `false` if the body ended, `true` otherwise.
    mutating func read(
        into parser: inout EventStreamParser,
        events: inout [ServerSentEvent]
    ) async throws -> Bool {
        switch source {
        #if !canImport(FoundationNetworking)
        case .bytes(var iterator):
            defer { source = .bytes(iterator) }
            while let byte = try await iterator.next() {
                scratch.append(byte)
                // Events, `id` and `retry` only take effect at the end of a line, so handing the
                // parser complete lines loses no latency while amortizing the parser call.
                if byte == 0x0A || byte == 0x0D || scratch.count >= Self.flushThreshold {
                    events.append(contentsOf: parser.parse(scratch))
                    scratch.removeAll(keepingCapacity: true)
                    if !events.isEmpty {
                        return true
                    }
                }
            }
        #endif
        case .chunks(var iterator):
            defer { source = .chunks(iterator) }
            while let chunk = try await iterator.next() {
                events.append(contentsOf: parser.parse(chunk))
                if !events.isEmpty {
                    return true
                }
            }
        }
        // A stream iterator also returns nil when the consuming task is cancelled.
        try Task.checkCancellation()
        // Bytes after the last line terminator form an unterminated line, which cannot dispatch
        // anything; the caller finishes the parser, which discards it.
        scratch.removeAll()
        return false
    }

    /// Reads up to `limit` bytes of the body for an error report.
    ///
    /// A read error ends the prefix early.
    mutating func readPrefix(limit: Int) async -> Data {
        var prefix = Data()
        do {
            switch source {
            #if !canImport(FoundationNetworking)
            case .bytes(var iterator):
                defer { source = .bytes(iterator) }
                while prefix.count < limit, let byte = try await iterator.next() {
                    prefix.append(byte)
                }
            #endif
            case .chunks(var iterator):
                defer { source = .chunks(iterator) }
                while prefix.count < limit, let chunk = try await iterator.next() {
                    prefix.append(chunk.prefix(limit - prefix.count))
                }
            }
        } catch {
            // The prefix is diagnostic only; keep what was read.
        }
        return prefix
    }
}
