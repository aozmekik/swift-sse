# Contributing

Thanks for your interest. This is a small, early project: bug reports with a failing stream (the
raw bytes, or a test) are the most useful contribution.

## Requirements

- Swift 6.0 or later. Development happens with the Swift that ships with the latest Xcode; Linux
  works with the official `swift` container images.
- macOS with Xcode for the documentation build (`xcrun docc`).
- Python 3 for the example fixture server (standard library only).

## Commands

```sh
swift build                          # debug build of every target
swift build -c release               # release build, as CI does
swift test                           # all tests (Swift Testing)
swift test --filter Parser           # one group of suites
swift test --sanitize=thread         # data race detection (macOS)
swift test --enable-code-coverage    # coverage; see below for the report

swift format lint --strict --recursive --parallel Package.swift Sources Tests examples Benchmarks
swift format format --in-place --recursive Package.swift Sources Tests examples Benchmarks

scripts/build-docs.sh                # DocC catalogs, warnings as errors (macOS)
scripts/check-examples.sh            # runs the examples offline and over local HTTP
swift run -c release sse-benchmark   # parser throughput

actionlint                           # if you change .github/workflows
```

Line coverage of the libraries, as quoted in the README (macOS):

```sh
swift test --enable-code-coverage
xcrun llvm-cov report \
    .build/debug/swift-ssePackageTests.xctest/Contents/MacOS/swift-ssePackageTests \
    -instr-profile .build/debug/codecov/default.profdata Sources   # or Sources/SSE, Sources/SSELLM
```

The libraries for the other Apple platforms, as CI builds them (macOS with Xcode):

```sh
swift build --target SSELLM --triple arm64-apple-ios16.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"
swift build --target SSELLM --triple arm64-apple-tvos16.0 --sdk "$(xcrun --sdk appletvos --show-sdk-path)"
swift build --target SSELLM --triple arm64_32-apple-watchos9.0 --sdk "$(xcrun --sdk watchos --show-sdk-path)"
swift build --target SSELLM --triple arm64-apple-xros1.0 --sdk "$(xcrun --sdk xros --show-sdk-path)"
```

The `Loopback HTTP` suite starts a small HTTP server on `127.0.0.1` (an ephemeral port) to check
what only the bytes on the wire show; its flow control test pauses for one second of real time.

## Guidelines

- Keep the public API small and documented: every public declaration needs a documentation
  comment (the lint configuration enforces it).
- Behaviour that the standard defines should cite the section, and a conformance test should
  reproduce the case. Behaviour that goes beyond the standard needs a sentence in the README's
  design notes, and an ADR in `docs/adr/` if it is a real decision with alternatives.
- Tests must not depend on timing: inject the sleeper and the random source (see
  `Tests/SSETests/Support/StubTransport.swift`) instead of waiting for real time. Where a real
  pause is unavoidable (the loopback flow control test), the assertion must hold however long
  the pause lasts.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).
- Benchmark numbers in the README and `docs/benchmarks.md` must come from a run of
  `sse-benchmark` and state the machine, the toolchain and the load on the machine.
