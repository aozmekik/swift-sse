# Assembling Streamed Text

Show a model's answer as it is generated, then keep the complete message.

## Overview

An LLM stream delivers a response as many small events. A user interface wants each text fragment
as soon as it arrives; the rest of the app usually wants the finished message: its text, its tool
calls with complete JSON arguments, why generation stopped, and how many tokens it used. The
accumulators give you both from the same loop.

### OpenAI-compatible servers

```swift
var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
request.httpMethod = "POST"
request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = requestBody  // {"model": ..., "stream": true, "messages": [...]}

var completion = OpenAIChatCompletionAccumulator()
for try await chunk in EventSource(request: request).openAIChatCompletionChunks() {
    show(chunk.textDelta ?? "")
    completion.add(chunk)
}

for call in completion.choices.first?.toolCalls ?? [] {
    let arguments = try call.decodeArguments(as: WeatherQuery.self)
    // ...
}
```

The sequence ends at `data: [DONE]`. If the server closes the connection before that, iteration
throws ``LLMStreamError/truncated``, so a cut-off answer is never mistaken for a complete one.

### Anthropic Messages

```swift
var message = AnthropicMessageAccumulator()
for try await event in EventSource(request: request).anthropicStreamEvents() {
    show(event.textDelta ?? "")
    try message.add(event)
}

if message.stopReason == .toolUse {
    for toolUse in message.toolUses {
        let input = try toolUse.decodeInput(as: WeatherQuery.self)
        // ...
    }
}
```

An `error` event, such as `overloaded_error`, ends the sequence with
``LLMStreamError/provider(_:)``. Unknown event, block and delta types are passed through with
their JSON instead of failing, because the API may add new ones.

### Cancellation

Generation stops costing tokens only when the connection closes. Cancel the task that runs the
loop (for example by leaving a SwiftUI view whose `.task` runs it) or break out of the loop: both
close the HTTP connection immediately.
