# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0, minor versions may
contain breaking changes.

## [Unreleased]

## [0.1.0] - 2026-10-18

### Known issues

- No flow control on Linux: swift-corelibs-foundation keeps reading after
  `URLSessionTask.suspend()`, and with Swift 6.4 resuming the task replayed the stream, so the
  Linux bridge never suspends and a slow consumer's unread data piles up in memory. Apple platforms
  use `URLSession.bytes` and are not affected.

### Added

- `EventStreamParser`: an incremental, byte-level parser for `text/event-stream` implementing
  WHATWG HTML Living Standard sections 9.2.5 and 9.2.6.
- `EventSource`: a pull-based `AsyncSequence` client over `URLRequest`, using
  `URLSession.bytes(for:)` on Apple platforms and a `URLSessionDataDelegate` bridge with flow
  control on Linux, with status and `Content-Type` validation, cancellation, the `Accept`,
  `Cache-Control` and `Pragma` request headers of the standard's "no-store" fetch, and
  `Last-Event-ID` sent as UTF-8 bytes (also through CFNetwork, which writes ISO-8859-1).
- `ReconnectionPolicy`: the server's `retry` time as a floor, capped exponential backoff with
  jitter, an optional attempt limit, and `.disabled`; non-`GET` requests do not reconnect by
  default, a connection that delivers any data resets the backoff, and errors that no
  reconnection can fix are not retried.
- `EventSourceError` with the response and the start of the body (at most 64 KiB, read for at
  most one second) for HTTP failures.
- `SSELLM`: decoders, `AsyncSequence` adapters and accumulators for OpenAI-compatible Chat
  Completions streams (including servers that omit tool call indices) and Anthropic Messages
  streams; `LLMStreamError`, `ProviderError` and `JSONValue` (exact `Int64` integers).
- Examples (`assemble-text`, `sse-tail`, `serve-fixture.py`), a parser and accumulator
  benchmark, DocC catalogs, ADRs, and CI for macOS, Linux and builds for iOS, tvOS, watchOS and
  visionOS.

[Unreleased]: https://github.com/aozmekik/swift-sse/compare/0.1.0...HEAD
[0.1.0]: https://github.com/aozmekik/swift-sse/releases/tag/0.1.0
