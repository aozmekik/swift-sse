# ADR 0003: Parse bytes, not Foundation lines or Strings

- Status: accepted
- Date: 2026-10-18

## Context

The quickest way to read an event stream on Apple platforms is
`URLSession.bytes(for:).lines`. Foundation's `AsyncLineSequence` does not implement the
`text/event-stream` line rules. On macOS 26 with Swift 6.3.2, reading a file that contains
`data: a<U+2028>b\n\ndata: c\r\n\r\nid: x<U+0085>y\n\n` through `URL.lines` produced:

```
["data: a", "b", "data: c", "id: x", "y"]
```

It splits lines at U+2028 and U+0085, which the standard treats as ordinary characters, and it
drops empty lines, which are what dispatches an event. A parser on top of it cannot be correct.

## Options considered

1. **`AsyncLineSequence`**: rejected, see above.
2. **Decode the stream to `String` and split it**: correct if done carefully, but it decodes
   bytes the parser never needs (comments, unknown fields), and Swift's `Character` treats `\r\n`
   as one grapheme, which invites mistakes; splitting must then be done on Unicode scalars.
3. **A byte-level state machine** that splits lines at `CR`, `LF` and `CRLF` bytes, matches field
   names as bytes, and decodes UTF-8 only for the values it keeps.

## Decision

Option 3: `EventStreamParser` works on `UnsafeBufferPointer<UInt8>` chunks, carries partial lines,
a pending `CR` and a partially matched byte order mark across chunks, and builds `String`s only
for `data`, `event` and `id` values. `CR` and `LF` never occur inside a multi-byte UTF-8 sequence,
so per-field decoding gives the same result as decoding the whole stream first; Swift's
`String(decoding:as:)` replaces invalid sequences with U+FFFD as the Encoding standard's UTF-8
decoder does (both checked by tests).

## Consequences

- Chunk boundaries cannot change the result. Tests check every single and pair split point of the
  fixtures, byte-at-a-time feeding, and 2,000 seeded random streams against a naive reference
  implementation of option 2.
- The parser is a pure value type usable with any byte source, including tests and other HTTP
  clients.
- Throughput is high enough not to matter next to the network (see the README benchmark).
- The client feeds the parser complete lines from `URLSession.AsyncBytes`, so it iterates bytes
  one at a time on Apple platforms; the Linux path receives chunks from the delegate.
