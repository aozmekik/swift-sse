# swift-sse

A spec-compliant Server-Sent Events client for Swift Concurrency, built for streaming LLM APIs on
iOS, macOS and Linux.

[![CI](https://github.com/aozmekik/swift-sse/actions/workflows/ci.yml/badge.svg)](https://github.com/aozmekik/swift-sse/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Status: early (v0.1.0). The API may change before 1.0.**

```swift
for try await chunk in EventSource(request: chatRequest).openAIChatCompletionChunks() {
    print(chunk.textDelta ?? "", terminator: "")
}
```

## Why

Streaming LLM responses on Apple platforms usually starts with `URLSession.bytes(for:).lines` and
a hand-written `data:` prefix check. That breaks on real streams: Foundation's line sequence drops
the empty lines that delimit events and splits lines at U+2028 and U+0085
([ADR 0003](docs/adr/0003-byte-level-parser.md) shows the reproduction), multi-line `data` is
lost, and the `id`/`retry` reconnection machinery is ignored. This package implements the
[WHATWG HTML Living Standard, section 9.2 "Server-sent events"](https://html.spec.whatwg.org/multipage/server-sent-events.html)
properly, exposes it as an `AsyncSequence`, and adds typed decoders for the two most common LLM
streaming formats.

## Features

- **Spec parser** (`EventStreamParser`, sections 9.2.5 and 9.2.6): `CR`, `LF` and `CRLF` line
  endings (including `CRLF` split across chunks), a single leading BOM (also when split), comments,
  `event`/`data`/`id`/`retry` fields, multi-line data, `id` values containing NULL ignored,
  non-digit `retry` values ignored, unterminated final blocks discarded, invalid UTF-8 replaced
  with U+FFFD. Pure value type, usable with any byte source.
- **Client** (`EventSource`, section 9.2.3): an `AsyncSequence` over a `URLRequest` (any method,
  headers and body), `URLSession.bytes(for:)` on Apple platforms and a FoundationNetworking path on
  Linux, `Accept` and `Last-Event-ID` headers, HTTP status and `Content-Type` validation with typed
  errors that carry the error body, `204 No Content` as a clean stop.
- **Reconnection** (`ReconnectionPolicy`): the server's `retry:` as a floor, capped exponential
  backoff with jitter after consecutive failures, an optional attempt limit, and `.disabled` for
  streams that must not be replayed. Non-`GET` requests do not reconnect unless you ask.
- **Cancellation**: cancelling the iterating task, or breaking out of the loop, cancels the HTTP
  request. No unstructured tasks inside.
- **LLM helpers** (`SSELLM`, a separate library product): typed decoding of OpenAI-compatible
  `chat.completion.chunk` streams (with `[DONE]` and in-stream errors) and Anthropic Messages
  streaming events, sequences that stop at the terminal event and detect truncated streams, and
  accumulators that assemble text, tool call arguments, thinking blocks, stop reasons and usage.
- Swift 6 language mode with strict concurrency, no dependencies.

## Install

Swift Package Manager (not yet published to the Swift Package Index):

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/aozmekik/swift-sse", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SSE", package: "swift-sse"),
        .product(name: "SSELLM", package: "swift-sse"),  // optional LLM helpers
    ]),
]
```

In Xcode: File > Add Package Dependencies, then enter `https://github.com/aozmekik/swift-sse`.

Requirements: Swift 6.0 or later; iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, or Linux with
FoundationNetworking.

## Quick start

```swift
import SSE

let events = EventSource(url: URL(string: "https://example.com/updates")!)
for try await event in events {
    print(event.type, event.lastEventID, event.data)
}
```

`GET` streams reconnect automatically with `Last-Event-ID`. Leaving the loop closes the connection.

## Usage

### Streaming an LLM response

```swift
import SSE
import SSELLM

var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
request.httpMethod = "POST"
request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = body  // {"model": ..., "stream": true, "messages": [...]}

var completion = OpenAIChatCompletionAccumulator()
for try await chunk in EventSource(request: request).openAIChatCompletionChunks() {
    print(chunk.textDelta ?? "", terminator: "")
    completion.add(chunk)
}
print("\n", completion.choices.first?.finishReason ?? "none")
```

Anthropic's Messages API works the same way:

```swift
var message = AnthropicMessageAccumulator()
for try await event in EventSource(request: request).anthropicStreamEvents() {
    print(event.textDelta ?? "", terminator: "")
    try message.add(event)
}
for toolUse in message.toolUses {
    let input = try toolUse.input  // JSONValue, or decodeInput(as: MyInput.self)
    print(toolUse.name, input)
}
```

Both sequences stop at the terminal event (`data: [DONE]`, `message_stop`) without reading
further, throw `LLMStreamError.provider` for errors sent inside the stream (such as Anthropic's
`overloaded_error`), and throw `LLMStreamError.truncated` if the connection closes before the
terminal event.

### SwiftUI

Run the loop in `.task`: SwiftUI cancels the task when the view disappears, and the request is
cancelled with it, so the model stops generating.

```swift
import SSE
import SSELLM
import SwiftUI

struct AnswerView: View {
    let request: URLRequest  // a streaming Chat Completions request
    @State private var answer = ""
    @State private var failure: String?

    var body: some View {
        ScrollView {
            Text(answer)
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .task {
            do {
                for try await chunk in EventSource(request: request).openAIChatCompletionChunks() {
                    answer += chunk.textDelta ?? ""
                }
            } catch is CancellationError {
                // The view went away; the HTTP request was cancelled with the task.
            } catch {
                failure = String(describing: error)
            }
        }
    }
}
```

### Reconnection

```swift
let events = EventSource(
    request: request,
    reconnection: .exponentialBackoff(
        reconnectionTime: .seconds(1),
        maximumDelay: .seconds(30),
        maximumAttempts: 10
    ),
    lastEventID: UserDefaults.standard.string(forKey: "lastEventID") ?? ""
)
```

| Consecutive failed attempt | Delay before jitter (defaults) | With the default jitter of 0.5 |
|---|---|---|
| 1 | 3 s, or the server's `retry:` | 3 s to 4.5 s |
| 2 | 6 s | 6 s to 9 s |
| 3 | 12 s | 12 s to 18 s |
| 6 and later | 60 s (the cap) | 60 s to 90 s |

A failed attempt is a connection that failed or closed without sending anything; a connection
that delivers data, even only keep-alive comments, resets the count. Errors that no reconnection
can fix (an unsupported URL, an untrusted certificate, cancelled authentication) throw
`connectionFailed` at once. The default for `GET` requests is `.default` (the table above,
retrying forever, as browsers do); for every other method it is `.disabled`. See
[ADR 0002](docs/adr/0002-reconnection-delay.md) and [ADR 0004](docs/adr/0004-reconnect-only-get-by-default.md).

### Errors

```swift
do {
    for try await event in events {
        print(event.data)
    }
} catch EventSourceError.unexpectedStatusCode(let status, let response, let body) {
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After") ?? "-"
    print(status, retryAfter, String(decoding: body, as: UTF8.self))
} catch LLMStreamError.provider(let error) {
    print("provider error:", error)
} catch {
    print(error)
}
```

| Situation | Result |
|---|---|
| 200 with `text/event-stream` (parameters ignored) | events |
| 204 No Content | the sequence ends normally |
| any other status | `EventSourceError.unexpectedStatusCode` with the response and the start of the body (up to 64 KiB, read for at most 1 s), not retried |
| 200 with another content type | `EventSourceError.unexpectedContentType`, likewise, not retried |
| network error or end of stream | reconnect per policy; with `.disabled`, `connectionFailed` or the end of the sequence |
| attempt limit reached | `EventSourceError.reconnectionLimitReached` |
| task cancelled | `CancellationError`, request cancelled |

### Parsing bytes yourself

```swift
var parser = EventStreamParser()
for chunk in chunks {                 // any Sequence<UInt8>: Data, [UInt8], buffers
    for event in parser.parse(chunk) {
        print(event.data)
    }
}
parser.finish()                       // end of stream: an unterminated block is discarded
print(parser.lastEventID, parser.reconnectionTime ?? .zero)
```

### API overview

| Module | Type | Role |
|---|---|---|
| `SSE` | `EventSource` | `AsyncSequence` client over a `URLRequest` |
| | `ServerSentEvent` | `type`, `data`, `lastEventID` |
| | `ReconnectionPolicy` | `.default`, `.disabled`, `.exponentialBackoff(...)` |
| | `EventSourceError` | typed failures |
| | `EventStreamParser` | incremental byte parser |
| `SSELLM` | `OpenAIChatStreamEvent`, `OpenAIChatCompletionChunk` | OpenAI-compatible decoding |
| | `AnthropicStreamEvent` | Anthropic Messages decoding |
| | `openAIChatCompletionChunks()`, `anthropicStreamEvents()` | sequences on any `AsyncSequence<ServerSentEvent>` |
| | `OpenAIChatCompletionAccumulator`, `AnthropicMessageAccumulator` | assemble the final message |
| | `LLMStreamError`, `ProviderError`, `JSONValue` | shared types |

Every public declaration has documentation comments; the DocC catalogs (`Sources/SSE/SSE.docc`,
`Sources/SSELLM/SSELLM.docc`) add a getting-started guide and articles on reconnection and on
assembling streamed text. Build them with `scripts/build-docs.sh` (macOS).

### Examples

[`examples/`](examples) has two runnable command-line tools, `assemble-text` (LLM text assembly
from a file or URL) and `sse-tail` (prints any SSE endpoint, reconnecting), plus a small Python
fixture server for running them over real HTTP without an API key.

## Design notes and trade-offs

- **Pull-based iteration** ([ADR 0001](docs/adr/0001-pull-based-async-sequence.md)): `next()`
  performs the I/O, so there is no background task, no unbounded buffer, and no reconnection
  unless the consumer asks for another event. The trade-off: no `readyState`/`onerror`
  observation, and each iterator opens its own connection.
- **Byte-level parsing** ([ADR 0003](docs/adr/0003-byte-level-parser.md)): field names are
  matched as bytes and only kept values are decoded as UTF-8. Chunking cannot change the result.
- **Spec floor plus backoff** ([ADR 0002](docs/adr/0002-reconnection-delay.md)): the server's
  `retry:` is never undercut, failures back off from the client's own base, and jitter is added,
  never subtracted.
- **Safe defaults for `POST`** ([ADR 0004](docs/adr/0004-reconnect-only-get-by-default.md)):
  replaying an LLM request would bill a new generation.
- **Behaviour choices beyond the standard**: the last event ID persists across reconnections
  (as browsers do and web-platform-tests `format-field-id-2` requires); `204` ends the sequence
  without an error; HTTP status errors include the start of the body because LLM APIs explain
  failures there; the `Accept` header is only set when the request has none.
- **Linux**: FoundationNetworking has no `URLSession.bytes(for:)`, so Linux uses a
  `URLSessionDataDelegate` bridge built from your session's configuration (its delegate is not
  used). The same bridge is exercised on macOS by the test suite.

## Testing

```sh
swift test
```

- 133 tests in 11 suites (Swift Testing's count; a parameterized test counts once), measured with
  `swift test` on an Apple M1 Pro (16 GB), macOS 26.6.2, Swift 6.3.2 (Xcode 26.5).
- Parser conformance: every example of section 9.2.6 and the streams of the web-platform-tests
  `eventsource/format-*` files; every single and every pair of split points of the fixtures;
  byte-at-a-time feeding; 2,000 seeded random streams checked against a naive reference parser
  (`Tests/SSETests/Support/ReferenceParser.swift`).
- Client: reconnection, backoff, validation and cancellation with a scripted transport and an
  injected sleeper and random source (no test waits for real time); `URLProtocol`-backed tests that
  run both `URLSession` transports on Apple platforms.
- The suite also passes under `swift test --sanitize=thread` and `--sanitize=address` (same
  machine and toolchain).
- Line coverage of `Sources/`: 97.6% (SSE 97.8%, SSELLM 97.4%), on the machine above, from
  `swift test --enable-code-coverage` and then
  `xcrun llvm-cov report .build/debug/swift-ssePackageTests.xctest/Contents/MacOS/swift-ssePackageTests -instr-profile .build/debug/codecov/default.profdata Sources`
  (`Sources/SSE` or `Sources/SSELLM` for one module). It covers the code compiled on macOS; the
  Linux-only lines are a few `#if` branches.
- Linux runs the same suites except the `URLProtocol`-backed ones, which are Apple-only.

## Benchmarks

Parser throughput on synthetic streams generated in memory (no I/O, no networking, no JSON
decoding), median of 7 runs after one warm-up, `(min-max)` across runs:

```sh
swift run -c release sse-benchmark
```

Apple M1 Pro (8 cores, 16 GB), macOS 26.6.2, Swift 6.3.2, release build, 64 MiB per workload
(16 MiB for `tiny`):

| Workload | Chunk size | MiB/s | Million events/s |
|---|---:|---:|---:|
| `llm-chunks`: OpenAI-style chunk events, ~180 B each | 64 B | 464 (399-511) | 2.69 |
| | 1 KiB | 691 (381-695) | 4.00 |
| | 16 KiB | 777 (726-871) | 4.50 |
| `multi-line`: id, event, 8 data lines of 72 B, CRLF | 64 B | 586 (578-591) | 0.92 |
| | 1 KiB | 993 (983-998) | 1.56 |
| | 16 KiB | 1143 (1133-1159) | 1.79 |
| `tiny`: `data: x` events | 64 B | 82 (78-83) | 9.57 |
| | 1 KiB | 125 (123-130) | 14.62 |
| | 16 KiB | 116 (34-134) | 13.57 |

These numbers are noisy: the machine was shared with other heavy build jobs. The run above
started at a one-minute load average of about 15 on 8 cores; an earlier run in the same hour, at a
load average of about 80, measured between 42% and 61% of these medians (for example 681 MiB/s
for `multi-line` at 16 KiB), and the wide ranges of some rows (`tiny` at 16 KiB) come from the same interference.
Treat the figures as an order of magnitude: hundreds of MiB per second, far above what an LLM or
event stream delivers over a network, so parsing is not the bottleneck. The client path
(`URLSession.AsyncBytes`, one byte per `await`) is not benchmarked.

## Limitations

- No limit on the size of a single event or line: a server that never sends a line terminator
  makes the parser buffer without bound. Use it with servers you trust, or put a byte limit in
  your own transport.
- No `readyState`, `open` or `error` notifications while the client reconnects; reconnection is
  only visible through the delays and the `Last-Event-ID` the server receives.
- On Linux, the `URLSession` delegate of the session you pass is not used (only its
  configuration), and FoundationNetworking's HTTP stack has its own limits.
- Status codes such as `429` and `503` are not retried, as the standard requires; `Retry-After` is
  available on the error for your own retry logic.
- `SSELLM` decodes responses only: it does not build requests or know model names, and it was
  tested against synthetic streams written from the providers' documentation, not against live
  APIs. Provider-specific extensions (for example `reasoning_content` fields of some
  OpenAI-compatible servers) are not modelled.
- Development and every measurement above used Swift 6.3.2 on macOS. The manifest declares Swift
  6.0 as the minimum, and the Linux CI job builds and tests with Swift 6.0, 6.3 and 6.4, but at the
  time of writing that job had not run yet: Linux support is implemented, not yet verified.

## Roadmap

- An optional per-event size limit with a typed error.
- Reconnection observation (attempt number, delay, error) for status UI.
- A pluggable transport for other HTTP clients, such as AsyncHTTPClient on Linux.
- Optional retry of `429`/`503` honoring `Retry-After`.
- Publishing to the Swift Package Index once the API settles.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the build, test, lint and documentation commands.
Issues and pull requests are welcome; please include a test that fails without your change.

## References

- WHATWG, [HTML Living Standard, section 9.2 "Server-sent events"](https://html.spec.whatwg.org/multipage/server-sent-events.html):
  9.2.3 Processing model, 9.2.4 The `Last-Event-ID` header, 9.2.5 Parsing an event stream,
  9.2.6 Interpreting an event stream.
- WHATWG, [Encoding Standard, UTF-8 decode](https://encoding.spec.whatwg.org/#utf-8-decode).
- [web-platform-tests `eventsource/`](https://github.com/web-platform-tests/wpt/tree/master/eventsource):
  the source of the `format-*` conformance cases reproduced in the tests.
- OpenAI, [Chat Completions streaming](https://platform.openai.com/docs/api-reference/chat-streaming).
- Anthropic, [Streaming Messages](https://docs.claude.com/en/docs/build-with-claude/streaming).
- Marc Brooker, [Exponential Backoff And Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/),
  AWS Architecture Blog, 2015.
- G. L. Steele Jr., D. Lea, C. H. Flood, "Fast splittable pseudorandom number generators",
  OOPSLA 2014 (SplitMix64, used by the randomized tests).

## License

MIT. See [LICENSE](LICENSE).

Built by [Ahmed Semih Özmekik](https://github.com/aozmekik) at [Fergani](https://fergani.tr).
