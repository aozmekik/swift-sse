// sse-tail: prints the events of a Server-Sent Events endpoint, reconnecting like a browser.
//
//   swift run sse-tail <url> [--max-events N] [--no-reconnect] [--last-event-id ID]
//
// Each event is printed as `[type] id=<last event ID>` followed by its data lines. Reconnection
// uses the default policy: the server's retry time, then a capped, jittered exponential backoff.
// Press Ctrl-C to stop.

import Foundation
import SSE

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct Options {
    var url: URL?
    var maximumEvents = Int.max
    var reconnects = true
    var lastEventID = ""
}

struct UsageError: Error, CustomStringConvertible {
    var description: String
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
        switch argument {
        case "--max-events":
            guard let text = remaining.popFirst(), let count = Int(text), count > 0 else {
                throw UsageError(description: "--max-events needs a positive number")
            }
            options.maximumEvents = count
        case "--no-reconnect":
            options.reconnects = false
        case "--last-event-id":
            guard let id = remaining.popFirst() else {
                throw UsageError(description: "--last-event-id needs a value")
            }
            options.lastEventID = id
        default:
            guard options.url == nil, let url = URL(string: argument), url.scheme != nil else {
                throw UsageError(description: "unexpected argument '\(argument)'")
            }
            options.url = url
        }
    }
    return options
}

func write(_ text: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data(text.utf8))
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    guard let url = options.url else {
        throw UsageError(description: "missing URL")
    }
    let events = EventSource(
        url: url,
        reconnection: options.reconnects ? .default : .disabled,
        lastEventID: options.lastEventID
    )
    var count = 0
    for try await event in events {
        let id = event.lastEventID.isEmpty ? "" : " id=\(event.lastEventID)"
        let data = event.data.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
        write("[\(event.type)]\(id)\n\(data)\n")
        count += 1
        if count >= options.maximumEvents {
            break
        }
    }
} catch let error as UsageError {
    write("sse-tail: \(error)\n", to: .standardError)
    write(
        "usage: sse-tail <url> [--max-events N] [--no-reconnect] [--last-event-id ID]\n",
        to: .standardError)
    exit(64)
} catch {
    write("sse-tail: \(error)\n", to: .standardError)
    exit(1)
}
