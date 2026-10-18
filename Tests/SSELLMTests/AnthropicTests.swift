import Foundation
import SSE
import SSELLM
import Testing

@Suite("Anthropic message streams")
struct AnthropicTests {
    private func decode(_ json: String, type: String = "message") throws -> AnthropicStreamEvent {
        try AnthropicStreamEvent(decoding: event(json, type: type))
    }

    // MARK: Decoding

    @Test("message_start decodes the message metadata and usage")
    func messageStart() throws {
        let decoded = try decode(
            """
            {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant",\
            "content":[],"model":"m","stop_reason":null,"stop_sequence":null,\
            "usage":{"input_tokens":25,"cache_read_input_tokens":3,"output_tokens":1}}}
            """)
        guard case .messageStart(let message) = decoded else {
            Issue.record("expected message_start, got \(decoded)")
            return
        }
        #expect(message.id == "msg_1")
        #expect(message.model == "m")
        #expect(message.role == "assistant")
        #expect(message.stopReason == nil)
        #expect(
            message.usage
                == AnthropicStreamEvent.Usage(
                    inputTokens: 25, outputTokens: 1, cacheReadInputTokens: 3))
    }

    @Test("Content block types decode, unknown ones keep their JSON")
    func contentBlocks() throws {
        func block(_ json: String) throws -> AnthropicStreamEvent.ContentBlock? {
            let payload = #"{"type":"content_block_start","index":2,"content_block":"# + json + "}"
            guard case .contentBlockStart(2, let block) = try decode(payload) else { return nil }
            return block
        }
        #expect(try block(#"{"type":"text","text":""}"#) == .text(""))
        #expect(
            try block(#"{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}"#)
                == .toolUse(id: "toolu_1", name: "get_weather", input: .object([:])))
        #expect(
            try block(#"{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{}}"#)
                == .serverToolUse(id: "srv_1", name: "web_search", input: .object([:])))
        #expect(
            try block(#"{"type":"thinking","thinking":"","signature":""}"#)
                == .thinking("", signature: ""))
        #expect(
            try block(#"{"type":"redacted_thinking","data":"EmwKAhgB"}"#)
                == .redactedThinking(data: "EmwKAhgB"))
        #expect(
            try block(#"{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[]}"#)
                == .other(
                    type: "web_search_tool_result",
                    payload: .object([
                        "type": .string("web_search_tool_result"),
                        "tool_use_id": .string("srv_1"),
                        "content": .array([]),
                    ])))
    }

    @Test("Delta types decode, unknown ones keep their JSON")
    func deltas() throws {
        func delta(_ json: String) throws -> AnthropicStreamEvent.Delta? {
            let payload = #"{"type":"content_block_delta","index":0,"delta":"# + json + "}"
            guard case .contentBlockDelta(0, let delta) = try decode(payload) else { return nil }
            return delta
        }
        #expect(try delta(#"{"type":"text_delta","text":"Hi"}"#) == .text("Hi"))
        #expect(
            try delta(#"{"type":"input_json_delta","partial_json":"{\"a\":"}"#)
                == .inputJSON(#"{"a":"#))
        #expect(try delta(#"{"type":"thinking_delta","thinking":"Hmm"}"#) == .thinking("Hmm"))
        #expect(try delta(#"{"type":"signature_delta","signature":"EqQB"}"#) == .signature("EqQB"))
        #expect(
            try delta(#"{"type":"citations_delta","citation":{"cited_text":"x"}}"#)
                == .citation(.object(["cited_text": .string("x")])))
        #expect(
            try delta(#"{"type":"future_delta","value":1}"#)
                == .other(
                    type: "future_delta",
                    payload: .object(["type": .string("future_delta"), "value": .integer(1)])))
    }

    @Test("message_delta, message_stop, ping, error and unknown events decode")
    func otherEvents() throws {
        #expect(
            try decode(
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89}}"#
            )
                == .messageDelta(
                    .init(
                        stopReason: .toolUse, stopSequence: nil,
                        usage: .init(outputTokens: 89))))
        #expect(
            try decode(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)
                == .messageDelta(.init(stopReason: .endTurn, stopSequence: nil, usage: nil)))
        #expect(
            try decode(#"{"type":"content_block_stop","index":1}"#) == .contentBlockStop(index: 1))
        #expect(try decode(#"{"type":"message_stop"}"#) == .messageStop)
        #expect(try decode(#"{"type": "ping"}"#, type: "ping") == .ping)
        #expect(
            try decode(
                #"{"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}"#,
                type: "error")
                == .error(ProviderError(type: "overloaded_error", message: "Overloaded")))
        #expect(
            try decode(#"{"type":"brand_new_event","x":true}"#)
                == .unknown(
                    type: "brand_new_event",
                    payload: .object(["type": .string("brand_new_event"), "x": .bool(true)])))
        #expect(AnthropicStreamEvent.StopReason.refusal.description == "refusal")
    }

    @Test("Payloads without a type or with malformed known types throw invalidPayload")
    func invalidPayloads() async {
        for json in [#"{"index":0}"#, #"{"type":"content_block_delta","index":0}"#, "not json"] {
            let error = await llmError { _ = try decode(json) }
            guard case .invalidPayload(let failed, _)? = error else {
                Issue.record("expected invalidPayload for \(json)")
                continue
            }
            #expect(failed.data == json)
        }
    }

    @Test("textDelta is set only for text deltas")
    func textDelta() throws {
        #expect(
            try decode(
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a"}}"#
            ).textDelta == "a")
        #expect(
            try decode(
                #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"a"}}"#
            ).textDelta == nil)
        #expect(try decode(#"{"type":"message_stop"}"#).textDelta == nil)
    }

    // MARK: Accumulation

    @Test("The accumulator assembles the fixture's text, stop reason and usage")
    func accumulatesFixture() throws {
        var message = AnthropicMessageAccumulator()
        for item in try fixtureEvents("anthropic-messages.sse") {
            try message.add(AnthropicStreamEvent(decoding: item))
        }
        #expect(message.text == "Each event carries a small text delta; the client joins them.")
        #expect(message.id == "msg_synthetic_0001")
        #expect(message.model == "example-model")
        #expect(message.stopReason == .endTurn)
        #expect(message.isComplete)
        #expect(
            message.usage
                == .init(
                    inputTokens: 21, outputTokens: 14, cacheCreationInputTokens: 0,
                    cacheReadInputTokens: 0))
    }

    @Test("Tool use input, thinking and signatures are assembled per block")
    func accumulatesBlocks() throws {
        let events = [
            #"{"type":"message_start","message":{"id":"msg_2","model":"m","role":"assistant"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"check."}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Okay"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":", checking."}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"citations_delta","citation":{}}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" \"San Francisco, CA\"}"}}"#,
            #"{"type":"content_block_delta","index":9,"delta":{"type":"text_delta","text":"ignored"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_2","name":"now","input":{"zone":"UTC"}}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"content_block_start","index":4,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_stop","index":4}"#,
            #"{"type":"content_block_start","index":5,"content_block":{"type":"web_search_tool_result","content":[]}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":89}}"#,
            #"{"type":"ping"}"#,
            #"{"type":"message_stop"}"#,
        ]
        var message = AnthropicMessageAccumulator()
        for json in events {
            try message.add(try decode(json))
        }

        #expect(message.content.count == 6)
        #expect(message.content[0] == .thinking("Let me check.", signature: "EqQB"))
        #expect(message.content[1] == .text("Okay, checking."))
        #expect(message.text == "Okay, checking.")
        #expect(message.stopReason == .toolUse)
        #expect(message.usage.outputTokens == 89)

        let toolUses = message.toolUses
        #expect(toolUses.map(\.id) == ["toolu_1", "toolu_2"])
        struct Location: Decodable, Equatable {
            var location: String
        }
        #expect(
            try toolUses[0].decodeInput(as: Location.self)
                == Location(location: "San Francisco, CA"))
        #expect(try toolUses[1].input == .object(["zone": .string("UTC")]))
        #expect(toolUses[1].inputJSON.isEmpty)

        guard case .toolUse(let serverTool) = message.content[4] else {
            Issue.record("expected a server tool use")
            return
        }
        #expect(serverTool.isServerTool)
        guard case .other("web_search_tool_result", _) = message.content[5] else {
            Issue.record("expected an unmodeled block")
            return
        }
    }

    @Test("A tool input that arrived complete keeps large integers exact")
    func initialInputPrecision() throws {
        var message = AnthropicMessageAccumulator()
        try message.add(
            try decode(
                #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"lookup","input":{"query":"x","id":9007199254740993}}}"#
            ))
        guard case .toolUse(let toolUse) = message.content.first else {
            Issue.record("expected a tool use")
            return
        }
        struct Input: Decodable, Equatable {
            var query: String
            var id: Int64
        }
        let input = try toolUse.decodeInput(as: Input.self)
        #expect(input == Input(query: "x", id: 9_007_199_254_740_993))
        #expect(try toolUse.input["id"] == .integer(9_007_199_254_740_993))
    }

    @Test("An error event throws a provider error from the accumulator")
    func accumulatorThrowsOnError() async throws {
        var message = AnthropicMessageAccumulator()
        let error = await llmError {
            try message.add(
                try decode(
                    #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
            )
        }
        #expect(error == .provider(ProviderError(type: "overloaded_error", message: "Overloaded")))
    }

    // MARK: Sequence

    @Test("The event sequence ends after message_stop without reading further")
    func sequenceStopsAtMessageStop() async throws {
        let counter = PullCounter()
        let events = ScriptedEvents(
            events: try fixtureEvents("anthropic-messages.sse") + [event("must not be read")],
            counter: counter)
        var decoded: [AnthropicStreamEvent] = []
        for try await item in events.anthropicStreamEvents() {
            decoded.append(item)
        }
        #expect(decoded.last == .messageStop)
        #expect(decoded.contains(.ping))
        #expect(counter.pulls == decoded.count)
        #expect(decoded.compactMap(\.textDelta).joined().hasPrefix("Each event"))
    }

    @Test("A stream that ends before message_stop throws truncated")
    func sequenceTruncated() async {
        let events = ScriptedEvents(
            events: [event(#"{"type":"message_start","message":{"id":"m","model":"m"}}"#)],
            counter: PullCounter())
        let error = await llmError {
            for try await _ in events.anthropicStreamEvents() {}
        }
        #expect(error == .truncated)
    }

    @Test("An error event ends the sequence with a provider error")
    func sequenceProviderError() async throws {
        let events = ScriptedEvents(
            events: [
                event(#"{"type":"error","error":{"type":"api_error","message":"Internal"}}"#)
            ],
            counter: PullCounter())
        var iterator = events.anthropicStreamEvents().makeAsyncIterator()
        let error = await llmError { _ = try await iterator.next() }
        #expect(error == .provider(ProviderError(type: "api_error", message: "Internal")))
        let afterError = try await iterator.next()
        #expect(afterError == nil)
    }
}
