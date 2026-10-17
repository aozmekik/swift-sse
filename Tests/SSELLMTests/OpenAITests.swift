import Foundation
import SSE
import SSELLM
import Testing

@Suite("OpenAI chat completion streams")
struct OpenAITests {
    // MARK: Decoding

    @Test("A content chunk decodes with its metadata")
    func decodesChunk() throws {
        let json = """
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1694268190,\
            "model":"m","system_fingerprint":"fp_1","service_tier":"default","choices":[\
            {"index":0,"delta":{"role":"assistant","content":"Hi"},"logprobs":null,\
            "finish_reason":null}],"usage":null,"unknown_field":{"ignored":true}}
            """
        let chunk = try #require(try openAIChunks([json]).first)
        #expect(chunk.id == "chatcmpl-1")
        #expect(chunk.object == "chat.completion.chunk")
        #expect(chunk.created == 1_694_268_190)
        #expect(chunk.model == "m")
        #expect(chunk.systemFingerprint == "fp_1")
        #expect(chunk.serviceTier == "default")
        #expect(chunk.choices.first?.delta.role == "assistant")
        #expect(chunk.textDelta == "Hi")
        #expect(chunk.choices.first?.finishReason == nil)
        #expect(chunk.usage == nil)
    }

    @Test("[DONE] decodes as done", arguments: ["[DONE]", " [DONE] "])
    func decodesDone(data: String) throws {
        #expect(try OpenAIChatStreamEvent(decoding: event(data)) == .done)
    }

    @Test("Null and missing fields decode leniently")
    func lenientDecoding() throws {
        let chunks = try openAIChunks([
            #"{"choices":[{"delta":{"content":null,"tool_calls":null}},{"index":1}]}"#,
            "{}",
        ])
        let chunk = try #require(chunks.first)
        #expect(chunk.id == nil)
        #expect(chunk.choices.map(\.index) == [0, 1])
        #expect(chunk.choices[0].delta.toolCalls.isEmpty)
        #expect(chunk.choices[1].delta.content == nil)
        #expect(chunks.last?.choices.isEmpty == true)
    }

    @Test("A usage-only final chunk decodes usage details")
    func decodesUsage() throws {
        let json = """
            {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":12,"total_tokens":21,\
            "prompt_tokens_details":{"cached_tokens":4},\
            "completion_tokens_details":{"reasoning_tokens":2}}}
            """
        let chunk = try #require(try openAIChunks([json]).first)
        let usage = try #require(chunk.usage)
        #expect(chunk.textDelta == nil)
        #expect(usage.promptTokens == 9)
        #expect(usage.completionTokens == 12)
        #expect(usage.totalTokens == 21)
        #expect(usage.cachedPromptTokens == 4)
        #expect(usage.reasoningTokens == 2)

        let minimal = try #require(
            try openAIChunks([#"{"usage":{"prompt_tokens":1,"prompt_tokens_details":null}}"#]).first
        )
        #expect(minimal.usage?.completionTokens == 0)
        #expect(minimal.usage?.cachedPromptTokens == nil)
    }

    @Test("Finish reasons are an open set")
    func finishReasons() throws {
        let json = #"{"choices":[{"index":0,"delta":{},"finish_reason":"something_new"}]}"#
        let chunk = try #require(try openAIChunks([json]).first)
        #expect(chunk.choices[0].finishReason?.rawValue == "something_new")
        #expect(OpenAIChatCompletionChunk.FinishReason.toolCalls.rawValue == "tool_calls")
        #expect(OpenAIChatCompletionChunk.FinishReason.stop.description == "stop")
    }

    @Test("An error object in the stream decodes as an error")
    func decodesErrorEnvelope() throws {
        let json =
            #"{"error":{"message":"The server had an error","type":"server_error","code":500}}"#
        let expected = ProviderError(
            type: "server_error", message: "The server had an error", code: "500")
        #expect(try OpenAIChatStreamEvent(decoding: event(json)) == .error(expected))
        #expect(expected.description == "[server_error, code 500] The server had an error")
    }

    @Test(
        "An event named error decodes as an error, whatever its payload",
        arguments: [
            (#"{"error":{"message":"wrapped","code":"rate_limit"}}"#, "wrapped"),
            (#"{"message":"bare object"}"#, "bare object"),
            ("plain text", "plain text"),
        ]
    )
    func decodesErrorEvents(data: String, message: String) throws {
        let decoded = try OpenAIChatStreamEvent(decoding: event(data, type: "error"))
        guard case .error(let error) = decoded else {
            Issue.record("expected an error, got \(decoded)")
            return
        }
        #expect(error.message == message)
    }

    @Test("Invalid JSON throws invalidPayload with the event and a reason")
    func invalidPayload() async {
        let bad = event(#"{"choices":[{"index":"zero"}]}"#)
        let error = await llmError { _ = try OpenAIChatStreamEvent(decoding: bad) }
        guard case .invalidPayload(let failed, let reason)? = error else {
            Issue.record("expected invalidPayload")
            return
        }
        #expect(failed == bad)
        #expect(reason.contains("choices[0].index"))
        #expect(error?.description.contains("Could not decode") == true)

        let notJSON = await llmError { _ = try OpenAIChatStreamEvent(decoding: event("hello")) }
        guard case .invalidPayload(_, let notJSONReason)? = notJSON else {
            Issue.record("expected invalidPayload")
            return
        }
        #expect(notJSONReason.contains("invalid JSON"))
    }

    // MARK: Accumulation

    @Test("The accumulator joins the fixture's text and keeps the finish reason and usage")
    func accumulatesText() throws {
        var accumulator = OpenAIChatCompletionAccumulator()
        for item in try fixtureEvents("openai-chat.sse") {
            if case .chunk(let chunk) = try OpenAIChatStreamEvent(decoding: item) {
                accumulator.add(chunk)
            }
        }
        #expect(
            accumulator.text == "Server-Sent Events deliver a model's answer one token at a time.")
        #expect(accumulator.id == "chatcmpl-synthetic-0001")
        #expect(accumulator.model == "example-model")
        #expect(accumulator.choices.first?.role == "assistant")
        #expect(accumulator.choices.first?.finishReason == .stop)
        #expect(accumulator.usage?.totalTokens == 27)
    }

    @Test("Tool call fragments are assembled by index, with names taken once")
    func accumulatesToolCalls() throws {
        let chunks = try openAIChunks([
            #"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"get_time","arguments":"{\"zone\":\"UTC\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"get_weather","arguments":"\"Ankara\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])
        var accumulator = OpenAIChatCompletionAccumulator()
        for chunk in chunks {
            accumulator.add(chunk)
        }
        let choice = try #require(accumulator.choices.first)
        #expect(choice.finishReason == .toolCalls)
        #expect(choice.toolCalls.map(\.id) == ["call_a", "call_b"])
        #expect(choice.toolCalls.map(\.type) == ["function", "function"])
        #expect(choice.toolCalls.map(\.name) == ["get_weather", "get_time"])
        #expect(choice.toolCalls[0].arguments == #"{"city":"Ankara"}"#)

        struct Weather: Decodable, Equatable {
            var city: String
        }
        #expect(
            try choice.toolCalls[0].decodeArguments(as: Weather.self) == Weather(city: "Ankara"))
    }

    @Test("Arguments cut off mid-stream fail to decode")
    func truncatedArguments() throws {
        let chunks = try openAIChunks([
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]}}]}"#
        ])
        var accumulator = OpenAIChatCompletionAccumulator()
        for chunk in chunks {
            accumulator.add(chunk)
        }
        let call = try #require(accumulator.choices.first?.toolCalls.first)
        #expect(throws: DecodingError.self) {
            _ = try call.decodeArguments(as: [String: String].self)
        }
    }

    @Test("Several choices and refusals are kept apart")
    func accumulatesChoices() throws {
        let chunks = try openAIChunks([
            #"{"choices":[{"index":1,"delta":{"content":"B"}},{"index":0,"delta":{"content":"A"}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"a"}},{"index":1,"delta":{"refusal":"No"}}]}"#,
            #"{"choices":[{"index":1,"delta":{"refusal":"pe"}}]}"#,
        ])
        var accumulator = OpenAIChatCompletionAccumulator()
        for chunk in chunks {
            accumulator.add(chunk)
        }
        #expect(accumulator.choices.map(\.index) == [0, 1])
        #expect(accumulator.text == "Aa")
        #expect(accumulator.choices[1].content == "B")
        #expect(accumulator.choices[1].refusal == "Nope")
        #expect(accumulator.choices[0].refusal == nil)
    }

    // MARK: Sequence

    @Test("The chunk sequence stops at [DONE] without reading further")
    func sequenceStopsAtDone() async throws {
        let counter = PullCounter()
        let events = ScriptedEvents(
            events: [
                event(#"{"choices":[{"index":0,"delta":{"content":"a"}}]}"#),
                ServerSentEvent(type: "keepalive", data: "not json"),
                event(#"{"choices":[{"index":0,"delta":{"content":"b"}}]}"#),
                event("[DONE]"),
                event("must not be read"),
            ],
            counter: counter)

        var text = ""
        for try await chunk in events.openAIChatCompletionChunks() {
            text += chunk.textDelta ?? ""
        }
        #expect(text == "ab")
        #expect(counter.pulls == 4)
    }

    @Test("A stream that ends before [DONE] throws truncated")
    func sequenceTruncated() async {
        let events = ScriptedEvents(
            events: [event(#"{"choices":[{"index":0,"delta":{"content":"a"}}]}"#)],
            counter: PullCounter())
        let error = await llmError {
            for try await _ in events.openAIChatCompletionChunks() {}
        }
        #expect(error == .truncated)
    }

    @Test("An error payload ends the sequence with a provider error")
    func sequenceProviderError() async throws {
        let events = ScriptedEvents(
            events: [event(#"{"error":{"message":"overloaded","type":"server_error"}}"#)],
            counter: PullCounter())
        var iterator = events.openAIChatCompletionChunks().makeAsyncIterator()
        let error = await llmError { _ = try await iterator.next() }
        #expect(error == .provider(ProviderError(type: "server_error", message: "overloaded")))
        let afterError = try await iterator.next()
        #expect(afterError == nil)
    }
}
