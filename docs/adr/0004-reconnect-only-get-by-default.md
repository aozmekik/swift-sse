# ADR 0004: Only GET requests reconnect by default

- Status: accepted
- Date: 2026-10-18

## Context

Browser `EventSource` only sends `GET` requests and always reconnects. LLM APIs stream the
response to a `POST`. Reconnecting such a stream after it ends replays the request, which starts
a new generation and bills it again; a client that silently does that in a loop is an expensive
bug. Yet one client type should serve both kinds of stream.

## Options considered

1. **Always reconnect, as browsers do**, and document that LLM users must pass `.disabled`. One
   forgotten argument costs money.
2. **Never reconnect unless asked.** Safe, but loses the standard's behaviour for ordinary event
   streams, which is a large part of the reason to use an SSE client.
3. **Choose by method**: `GET` reconnects with the default policy, any other method does not,
   and an explicit `reconnection:` argument always wins.

## Decision

Option 3. `EventSource(request:session:reconnection:lastEventID:)` takes an optional policy; `nil`
means `.default` for `GET` and `.disabled` otherwise. `EventSource(url:)`, which always sends
`GET`, defaults to `.default`.

## Consequences

- Streaming an LLM response needs no extra argument to be safe.
- A `POST` endpoint that is a genuine resumable event stream needs `reconnection: .default`
  explicitly.
- The rule is covered by tests and stated in the API documentation of the initializer.
