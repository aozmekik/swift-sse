# Examples

Runnable from the package root with `swift run`. None of them needs an API key: the fixtures and
the local fixture server below cover every path.

| Example | What it shows |
|---|---|
| [`assemble-text`](assemble-text/main.swift) | Streams an OpenAI-compatible or Anthropic response, prints the text as it arrives and assembles it with the `SSELLM` accumulators. |
| [`sse-tail`](sse-tail/main.swift) | Prints the events of any SSE endpoint and reconnects like a browser (`Last-Event-ID`, server `retry`, backoff). |
| [`serve-fixture.py`](serve-fixture.py) | A standard-library Python server that streams a fixture file block by block, for trying the examples over real HTTP. |

## Offline, from a fixture file

```sh
swift run assemble-text --provider openai --file examples/fixtures/openai-chat.sse
swift run assemble-text --provider anthropic --file examples/fixtures/anthropic-messages.sse
```

## Over HTTP, against the local fixture server

```sh
python3 examples/serve-fixture.py examples/fixtures/openai-chat.sse --port 8080 &
swift run assemble-text --provider openai --url http://127.0.0.1:8080/v1/chat/completions \
    --body request.json   # any JSON body; the fixture server ignores it
```

Reconnection, with a server that closes the connection after every two blocks:

```sh
python3 examples/serve-fixture.py examples/fixtures/ticks.sse --port 8081 --max-blocks 2 &
swift run sse-tail http://127.0.0.1:8081/ --max-events 3
```

The server log shows the second request arriving with `Last-Event-ID: 1` and resuming after it.

## Against a real API

`assemble-text --url` sends whatever request you describe, so it works with any
OpenAI-compatible endpoint or the Anthropic Messages API, for example:

```sh
swift run assemble-text --provider anthropic --url https://api.anthropic.com/v1/messages \
    --header "x-api-key: $ANTHROPIC_API_KEY" --header "anthropic-version: 2023-06-01" \
    --body request.json   # a Messages request with "stream": true
```

This path is exercised in this repository only against the local fixture server, not against
live APIs.

## Fixtures

The files in [`fixtures/`](fixtures) are **synthetic**: written by hand to match the documented
OpenAI `chat.completion.chunk` and Anthropic Messages streaming formats. They are not captures of
real API responses. The test suite decodes them, so they stay valid.
