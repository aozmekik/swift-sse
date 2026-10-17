# Getting Started

Stream events from a server, from an LLM API, or from bytes you already have.

## Overview

An ``EventSource`` is an `AsyncSequence` of ``ServerSentEvent`` values. Iterating it opens the
connection; leaving the loop, or cancelling the task, closes it.

### Subscribe to an event stream

```swift
import SSE

let updates = EventSource(url: URL(string: "https://example.com/updates")!)
for try await event in updates {
    switch event.type {
    case "price": handlePrice(event.data)
    default: break
    }
}
```

`GET` streams reconnect automatically: when the server closes the stream or the network fails,
the event source waits for the server's reconnection time (its `retry:` field, 3 seconds by
default) and reconnects with a `Last-Event-ID` header, so the server can resume where it left off.
See <doc:ReconnectionAndBackoff>.

### Stream an LLM response

LLM APIs stream over `POST`. Requests with a method other than `GET` do not reconnect by default,
because replaying them would start, and bill, a new generation.

```swift
var request = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
request.httpBody = try JSONEncoder().encode(body)

for try await event in EventSource(request: request) {
    if event.data == "[DONE]" { break }
    print(event.data)
}
```

The `SSELLM` module turns these events into typed chunks and assembles the text and tool calls.

### Use it from SwiftUI

Run the loop in a task tied to the view's lifetime; SwiftUI cancels it when the view disappears,
which cancels the request.

```swift
struct LiveFeed: View {
    @State private var lines: [String] = []

    var body: some View {
        List(lines, id: \.self) { Text($0) }
            .task {
                do {
                    for try await event in EventSource(url: feedURL) {
                        lines.append(event.data)
                    }
                } catch is CancellationError {
                    // The view went away.
                } catch {
                    lines.append("Stream failed: \(error)")
                }
            }
    }
}
```

### Handle errors

Iteration throws an ``EventSourceError`` when the server answers with a status other than 200
(the error carries the response and the start of its body, which for LLM APIs usually explains the
problem), when the content type is not `text/event-stream`, or when the connection fails and the
policy does not reconnect. A `204 No Content` response ends the sequence normally. Cancelling the
task throws `CancellationError`.

```swift
do {
    for try await event in events { ... }
} catch EventSourceError.unexpectedStatusCode(let status, let response, let body) {
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
    print(status, retryAfter ?? "-", String(decoding: body, as: UTF8.self))
}
```

### Parse bytes yourself

``EventStreamParser`` has no I/O. Feed it chunks of any size, split anywhere:

```swift
var parser = EventStreamParser()
for try await chunk in myByteChunks {
    for event in parser.parse(chunk) {
        handle(event)
    }
}
parser.finish()  // Discards a final block that was not terminated by a blank line.
```

The parser keeps ``EventStreamParser/lastEventID`` and ``EventStreamParser/reconnectionTime``
across ``EventStreamParser/finish()``, so one parser can follow a stream across reconnections.
