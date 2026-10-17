# ``SSELLM``

Typed decoding of LLM streaming APIs on top of the `SSE` module.

## Overview

`SSELLM` turns the Server-Sent Events of two widely used streaming formats into Swift values:

- OpenAI-compatible Chat Completions streams: `chat.completion.chunk` objects terminated by
  `data: [DONE]`, as served by OpenAI and by many OpenAI-compatible servers.
- Anthropic Messages streams: `message_start`, `content_block_*`, `message_delta`,
  `message_stop`, `ping` and `error` events.

Each format has three layers, so you can stop at the one you need:

1. A decoder for single events: ``OpenAIChatStreamEvent/init(decoding:)`` and
   ``AnthropicStreamEvent/init(decoding:)``.
2. An `AsyncSequence` adapter that stops at the terminal event and turns in-stream errors and
   truncated streams into ``LLMStreamError`` values:
   `openAIChatCompletionChunks()` and `anthropicStreamEvents()` on any sequence of
   `ServerSentEvent`.
3. An accumulator that assembles the final message, including tool calls whose JSON arguments
   arrive in fragments: ``OpenAIChatCompletionAccumulator`` and ``AnthropicMessageAccumulator``.

```swift
import SSE
import SSELLM

var message = AnthropicMessageAccumulator()
for try await event in EventSource(request: messagesRequest).anthropicStreamEvents() {
    if let text = event.textDelta {
        print(text, terminator: "")
    }
    try message.add(event)
}
print("\nstop reason:", message.stopReason?.rawValue ?? "none")
```

This module decodes responses; it does not build requests, manage API keys or retry failed
generations.

## Topics

### Articles

- <doc:AssemblingStreamedText>

### OpenAI-compatible Chat Completions

- ``OpenAIChatStreamEvent``
- ``OpenAIChatCompletionChunk``
- ``OpenAIChatCompletionChunkSequence``
- ``OpenAIChatCompletionAccumulator``

### Anthropic Messages

- ``AnthropicStreamEvent``
- ``AnthropicStreamEventSequence``
- ``AnthropicMessageAccumulator``

### Shared types

- ``LLMStreamError``
- ``ProviderError``
- ``JSONValue``
