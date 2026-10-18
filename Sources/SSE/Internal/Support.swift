import Foundation

/// A value protected by a lock, for state shared with Foundation callbacks.
///
/// `Mutex` from the Synchronization module would be the modern choice, but it requires macOS 15
/// / iOS 18, above this package's deployment targets. `State` must be `Sendable` because values
/// put in on one thread are taken out on another; the lock only makes the access exclusive.
final class LockedState<State: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ state: State) {
        self.state = state
    }

    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

/// Helpers for the `Content-Type` check of section 9.2.2: the MIME type essence must be
/// `text/event-stream`, ignoring parameters such as `charset`.
enum MediaType {
    private static let eventStream = Array("text/event-stream".utf8)

    /// Whether `contentType` is `text/event-stream`, ignoring parameters, surrounding HTTP
    /// whitespace and ASCII case.
    static func isEventStream(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let utf8 = Array(contentType.utf8)
        let end = utf8.firstIndex(of: UInt8(ascii: ";")) ?? utf8.endIndex
        var essence = utf8[..<end]
        while let first = essence.first, isHTTPWhitespace(first) {
            essence.removeFirst()
        }
        while let last = essence.last, isHTTPWhitespace(last) {
            essence.removeLast()
        }
        return essence.elementsEqual(eventStream) { asciiLowercased($0) == $1 }
    }

    private static func isHTTPWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }
}
