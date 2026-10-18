# ADR 0001: EventSource is a pull-based AsyncSequence

- Status: accepted
- Date: 2026-10-18

## Context

The browser `EventSource` is an object with callbacks (`onopen`, `onmessage`, `onerror`) that
reconnects on its own in the background. A Swift client has to decide how events reach the caller
and who drives the connection. The main users are SwiftUI apps streaming LLM responses, where:

- cancelling the view's task must close the HTTP connection, because generation keeps costing
  tokens until the connection closes;
- the stream must stop at a terminal event (`[DONE]`, `message_stop`) without the client
  reconnecting and replaying a `POST`;
- Swift 6 strict concurrency must hold without `@unchecked Sendable` on the public types.

## Options considered

1. **Callback or delegate object**, mirroring the browser API. Familiar to web developers, but it
   needs a long-lived object with mutable state shared between the network callbacks and the
   caller, explicit `close()`, and its own answer to cancellation and back-pressure.
2. **`AsyncThrowingStream` fed by an internal `Task`** (push). Simple to write, but the producer
   task is unstructured: it runs ahead of the consumer (unbounded buffering), it can reconnect
   while nobody is listening, and cancellation has to be wired through `onTermination`.
3. **A custom `AsyncIteratorProtocol` whose `next()` performs the I/O** (pull). The iterator reads
   bytes only while the caller awaits the next event, and connects or reconnects only when asked
   for one.

## Decision

Option 3. `EventSource` is a `Sendable` value describing the request and policies;
`makeAsyncIterator()` returns an iterator that owns at most one connection. `next()` connects
lazily, reads until the parser dispatches an event, and on end of stream consults the
`ReconnectionPolicy` before reconnecting.

## Consequences

- Cancellation is structured: the request is cancelled by the task that awaits `next()`, and a
  `ConnectionLifetime` object cancels the request when the iterator is dropped, so `break` closes
  the connection too. Both are covered by URLProtocol-backed tests.
- No unstructured tasks inside the client, and the read-ahead is bounded, so back-pressure reaches
  the server through TCP. Pulling alone does not guarantee that: it bounds what the parser
  holds, not what the transport buffers. `URLSession.bytes(for:)` stops reading the socket when
  its own buffer is full, but `URLSessionDataDelegate` (the Linux transport) pushes every chunk
  as it arrives. The delegate bridge therefore counts unread bytes and suspends the data task
  above 1 MiB, resuming it at 256 KiB. A loopback test pauses the consumer while the server
  writes as fast as it can and checks that the server is held back.
- The LLM adapters can stop at the terminal event and simply stop calling `next()`: no reconnection
  can happen afterwards.
- Every iterator opens its own connection; iterating the same `EventSource` twice makes two
  requests. Fan-out to several consumers has to be built on top.
- There is no `readyState` and no `open` or `error` callback: a consumer cannot observe
  reconnection attempts while it waits. An observation hook is on the roadmap.
- The iterator is not `Sendable`, so one task consumes it, which is the normal `for try await`
  pattern.
