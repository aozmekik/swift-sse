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
swift test --enable-code-coverage    # coverage; report with xcrun llvm-cov report

swift format lint --strict --recursive --parallel Package.swift Sources Tests examples Benchmarks
swift format format --in-place --recursive Package.swift Sources Tests examples Benchmarks

scripts/build-docs.sh                # DocC catalogs, warnings as errors (macOS)
scripts/check-examples.sh            # runs the examples offline and over local HTTP
swift run -c release sse-benchmark   # parser throughput

actionlint                           # if you change .github/workflows
```

## Guidelines

- Keep the public API small and documented: every public declaration needs a documentation
  comment (the lint configuration enforces it).
- Behaviour that the standard defines should cite the section, and a conformance test should
  reproduce the case. Behaviour that goes beyond the standard needs a sentence in the README's
  design notes, and an ADR in `docs/adr/` if it is a real decision with alternatives.
- Tests must not depend on timing: inject the sleeper and the random source (see
  `Tests/SSETests/Support/StubTransport.swift`) instead of waiting for real time.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).
- Benchmark numbers in the README must come from a run of `sse-benchmark` and state the machine and
  toolchain.
