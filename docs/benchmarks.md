# Benchmarks

`sse-benchmark` (in `Benchmarks/sse-benchmark`) measures two things on synthetic data generated in
memory before timing starts:

- **Parser throughput**: `EventStreamParser` fed a 64 MiB stream (16 MiB for `tiny`) in chunks of
  64 B, 1 KiB and 16 KiB. Only parsing is timed: no I/O, no networking, no JSON decoding.
- **Accumulator scaling**: `OpenAIChatCompletionAccumulator` and `AnthropicMessageAccumulator`
  fed 5,000, 20,000 and 80,000 text deltas of 4 bytes, built in code (no JSON decoding). With a
  linear implementation the time per delta stays flat as the number of deltas grows.

Every configuration runs once to warm up and then 7 times; the tables give the median and, in
parentheses, the range across runs.

```sh
swift run -c release sse-benchmark            # full run, as below
swift run -c release sse-benchmark --quick    # smoke run (CI), numbers not meaningful
```

## Results

Apple M1 Pro (8 cores, 16 GB), macOS 26.6.2, Swift 6.3.2 (Xcode 26.5), release build, run on
2026-10-18. The machine was shared with other build jobs: the one-minute load average was about
35 when the run started and 31 when it ended, on 8 cores, so the figures are noisy: treat them as
orders of magnitude, not as precise rates.

### Parser

| Workload | Chunk size | MiB/s | Million events/s |
|---|---:|---:|---:|
| `llm-chunks`: OpenAI-style chunk events, ~180 B each, LF | 64 B | 512 (508-514) | 2.97 |
| | 1 KiB | 714 (712-715) | 4.13 |
| | 16 KiB | 905 (902-908) | 5.24 |
| `multi-line`: id, event, 8 data lines of 72 B, CRLF | 64 B | 592 (563-598) | 0.93 |
| | 1 KiB | 960 (917-968) | 1.51 |
| | 16 KiB | 1057 (919-1134) | 1.66 |
| `tiny`: `data: x` events, LF | 64 B | 81 (78-83) | 9.43 |
| | 1 KiB | 117 (56-127) | 13.64 |
| | 16 KiB | 117 (109-133) | 13.66 |

Hundreds of MiB per second is far above what an LLM or event stream delivers over a network, so
parsing is not the bottleneck. The client path (`URLSession.AsyncBytes`, one byte per `await`) is
not benchmarked.

### Accumulators

| Accumulator | Deltas | Total (ms) | ns per delta |
|---|---:|---:|---:|
| OpenAI | 5,000 | 1.4 (1.4-1.5) | 283 |
| | 20,000 | 5.6 (5.4-5.7) | 279 |
| | 80,000 | 21.9 (21.7-22.0) | 273 |
| Anthropic | 5,000 | 0.9 (0.9-1.0) | 186 |
| | 20,000 | 3.6 (3.5-3.7) | 179 |
| | 80,000 | 14.2 (14.0-14.3) | 177 |

Before the accumulators mutated their text in place, the same command on the same machine and
day (one-minute load average about 19 at the start) measured 2.0, 27.6 and 322.1 ms (OpenAI) and
2.1, 22.5 and 286.9 ms (Anthropic) for 5,000, 20,000 and 80,000 deltas: about 4 µs per delta at
80,000 and growing, a quadratic cost from copying the whole text on every delta.
