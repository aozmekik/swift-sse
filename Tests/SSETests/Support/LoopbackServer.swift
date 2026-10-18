import Foundation

@testable import SSE

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A minimal HTTP/1.1 server on `127.0.0.1`, for tests that need to see the bytes on the wire.
///
/// `URLProtocol` stubs see a `URLRequest` before the URL loading system serializes it, so they
/// cannot catch encoding problems in header values, and they bypass the transport's flow control.
/// This server speaks real TCP: every accepted connection is handed to `handler` on its own
/// thread, which reads the request head and writes whatever response the test scripts.
final class LoopbackServer: Sendable {
    /// The port the server listens on.
    let port: UInt16
    private let listener: Int32
    private let closed = LockedState(false)

    /// Starts listening on an ephemeral port of `127.0.0.1`.
    ///
    /// - Parameter handler: Called on a dedicated thread for every accepted connection; the
    ///   connection is closed when it returns.
    /// - Throws: ``LoopbackError`` if the socket cannot be set up.
    init(handler: @escaping @Sendable (LoopbackConnection) -> Void) throws {
        // A write to a connection the client has closed must fail with EPIPE instead of
        // terminating the test process.
        signal(SIGPIPE, SIG_IGN)

        #if canImport(Darwin)
        let socketType = SOCK_STREAM
        #else
        let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        let listener = socket(AF_INET, socketType, 0)
        guard listener >= 0 else { throw LoopbackError.system("socket", errno) }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length)
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            let code = errno
            _ = Glue.close(listener)
            throw LoopbackError.system("bind/listen", code)
        }
        var boundAddress = sockaddr_in()
        var boundLength = length
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &boundLength)
            }
        }
        guard named == 0 else {
            let code = errno
            _ = Glue.close(listener)
            throw LoopbackError.system("getsockname", code)
        }
        self.listener = listener
        self.port = UInt16(bigEndian: boundAddress.sin_port)

        let closed = self.closed
        let acceptor = Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else {
                    if errno == EINTR { continue }
                    return  // The listener was shut down.
                }
                guard !closed.withLock({ $0 }) else {
                    _ = Glue.close(client)
                    return
                }
                let worker = Thread {
                    let connection = LoopbackConnection(descriptor: client)
                    handler(connection)
                    connection.close()
                }
                worker.start()
            }
        }
        acceptor.start()
    }

    /// The URL of `path` on this server.
    func url(_ path: String = "/") -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            preconditionFailure("invalid loopback URL")
        }
        return url
    }

    /// Stops accepting connections.
    ///
    /// Connections that are open stay open until their handlers return.
    func stop() {
        let wasClosed = closed.withLock { closed in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        _ = shutdown(listener, Int32(SHUT_RDWR))
        _ = Glue.close(listener)
    }

    deinit {
        stop()
    }
}

/// One accepted TCP connection; used by a single handler thread.
final class LoopbackConnection {
    private let descriptor: Int32
    private var isClosed = false

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Reads up to the blank line that ends the request head.
    ///
    /// - Returns: The head, or `nil` if the client closed the connection first.
    func readRequestHead() -> LoopbackRequestHead? {
        // One byte at a time, so that nothing after the head (a request body) is consumed.
        var head: [UInt8] = []
        var byte: UInt8 = 0
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        while !head.ends(with: terminator) {
            let count = withUnsafeMutableBytes(of: &byte) { Glue.read(descriptor, $0) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            head.append(byte)
        }
        return LoopbackRequestHead(bytes: head)
    }

    /// Blocks until the client closes the connection, discarding anything it sends.
    func waitUntilClosed() {
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Glue.read(descriptor, $0) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
        }
    }

    /// Writes all of `bytes`.
    ///
    /// - Returns: `false` if the client closed the connection.
    @discardableResult
    func write(_ bytes: some Collection<UInt8>) -> Bool {
        let array = Array(bytes)
        var offset = 0
        while offset < array.count {
            let written = array.withUnsafeBytes { buffer in
                Glue.write(descriptor, UnsafeRawBufferPointer(rebasing: buffer[offset...]))
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// Writes `text` as UTF-8.
    @discardableResult
    func write(_ text: String) -> Bool {
        write(Array(text.utf8))
    }

    /// Writes a response head that announces an event stream delimited by closing the connection.
    @discardableResult
    func writeEventStreamHead(contentType: String = "text/event-stream", status: String = "200 OK")
        -> Bool
    {
        write(
            "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\n"
                + "Connection: close\r\n\r\n")
    }

    /// Closes the connection; later calls do nothing.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        _ = Glue.close(descriptor)
    }
}

/// The raw head of a request received by a ``LoopbackServer``.
struct LoopbackRequestHead: Sendable {
    /// Every byte of the head, including the final blank line.
    var bytes: [UInt8]

    /// The request line, such as `GET / HTTP/1.1`.
    var requestLine: String {
        let end = bytes.firstIndex(of: 0x0D) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// The raw bytes of the value of the first header named `name` (compared ignoring ASCII
    /// case), without the surrounding whitespace, or `nil` if there is no such header.
    func value(of name: String) -> [UInt8]? {
        let lines = bytes.split(separator: 0x0A).map { line in
            line.last == 0x0D ? line.dropLast() : line
        }
        let wanted = Array(name.lowercased().utf8)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { continue }
            let field = line[..<colon].map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
            guard field == wanted else { continue }
            var value = line[line.index(after: colon)...]
            while value.first == 0x20 || value.first == 0x09 { value = value.dropFirst() }
            while value.last == 0x20 || value.last == 0x09 { value = value.dropLast() }
            return Array(value)
        }
        return nil
    }
}

enum LoopbackError: Error {
    case system(String, Int32)
}

/// The C library functions whose names clash with methods of the types above.
private enum Glue {
    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
        #if canImport(Darwin)
        Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        #else
        Glibc.read(descriptor, buffer.baseAddress, buffer.count)
        #endif
    }

    static func write(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) -> Int {
        #if canImport(Darwin)
        Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        #else
        Glibc.write(descriptor, buffer.baseAddress, buffer.count)
        #endif
    }

    static func close(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(descriptor)
        #else
        Glibc.close(descriptor)
        #endif
    }
}

extension Array where Element == UInt8 {
    fileprivate func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && self[(count - suffix.count)...].elementsEqual(suffix)
    }
}
