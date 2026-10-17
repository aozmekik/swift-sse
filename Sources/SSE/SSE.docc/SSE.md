# ``SSE``

A Server-Sent Events client and parser for Swift Concurrency.

## Overview

`SSE` implements the `text/event-stream` format and the `EventSource` processing model of the
[WHATWG HTML Living Standard, section 9.2](https://html.spec.whatwg.org/multipage/server-sent-events.html)
on top of `URLSession`, as an `AsyncSequence`:

```swift
import SSE

for try await event in EventSource(url: URL(string: "https://example.com/updates")!) {
    print(event.type, event.data)
}
```

It has two layers:

- ``EventSource`` is the client. It sends the request, validates the response, parses the body,
  reconnects with `Last-Event-ID` according to a ``ReconnectionPolicy``, and stops when the
  iterating task is cancelled.
- ``EventStreamParser`` is the parser underneath: a pure value type that turns bytes from any
  source into ``ServerSentEvent`` values, so you can use it with your own networking stack, files
  or tests.

The companion `SSELLM` module decodes the event streams of OpenAI-compatible and Anthropic LLM
APIs on top of this module.

## Topics

### Essentials

- <doc:GettingStarted>
- ``EventSource``
- ``ServerSentEvent``

### Reconnection

- <doc:ReconnectionAndBackoff>
- ``ReconnectionPolicy``

### Errors

- ``EventSourceError``

### Parsing

- ``EventStreamParser``
