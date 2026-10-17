# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0, minor versions may
contain breaking changes.

## [Unreleased]

## [0.1.0] - 2026-10-18

### Added

- `EventStreamParser`: an incremental, byte-level parser for `text/event-stream` implementing
  WHATWG HTML Living Standard sections 9.2.5 and 9.2.6.
- `EventSource`: a pull-based `AsyncSequence` client over `URLRequest`, using
  `URLSession.bytes(for:)` on Apple platforms and a `URLSessionDataDelegate` bridge on Linux,
  with status and `Content-Type` validation, `Last-Event-ID`, and cancellation.
- `ReconnectionPolicy`: the server's `retry` time as a floor, capped exponential backoff with
  jitter, an optional attempt limit, and `.disabled`; non-`GET` requests do not reconnect by
  default.
- `EventSourceError` with the response and the start of the body for HTTP failures.
- `SSELLM`: decoders, `AsyncSequence` adapters and accumulators for OpenAI-compatible Chat
  Completions streams and Anthropic Messages streams; `LLMStreamError`, `ProviderError` and
  `JSONValue`.
- Examples (`assemble-text`, `sse-tail`, `serve-fixture.py`), a parser benchmark, DocC
  catalogs, ADRs and CI for macOS and Linux.

[Unreleased]: https://github.com/aozmekik/swift-sse/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aozmekik/swift-sse/releases/tag/v0.1.0
