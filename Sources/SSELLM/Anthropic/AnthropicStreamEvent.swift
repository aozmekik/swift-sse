import Foundation
import SSE

/// One event of an Anthropic Messages API stream.
///
/// A stream is `message_start`, then for each content block a `content_block_start`, its
/// `content_block_delta` events and a `content_block_stop`, then one or more `message_delta`
/// events and a final `message_stop`. `ping` events may appear anywhere, and `error` events report
/// failures such as `overloaded_error` after the HTTP response has started. See
/// <https://platform.claude.com/docs/en/build-with-claude/streaming>.
///
/// Event, block and delta types that this package does not model decode as ``unknown(type:payload:)``,
/// ``ContentBlock/other(type:payload:)`` and ``Delta/other(type:payload:)`` with their full JSON,
/// as the API's versioning policy asks clients to handle new types gracefully.
public enum AnthropicStreamEvent: Sendable, Hashable {
    /// The start of the response, with its metadata and initial usage.
    case messageStart(Message)
    /// The start of the content block at `index`.
    case contentBlockStart(index: Int, block: ContentBlock)
    /// An update of the content block at `index`.
    case contentBlockDelta(index: Int, delta: Delta)
    /// The end of the content block at `index`.
    case contentBlockStop(index: Int)
    /// Top-level changes to the message: the stop reason and cumulative usage.
    case messageDelta(MessageDelta)
    /// The end of the response.
    case messageStop
    /// A keep-alive event.
    case ping
    /// An error reported inside the stream.
    case error(ProviderError)
    /// An event type this package does not model.
    case unknown(type: String, payload: JSONValue)

    /// The text that this event adds to a text block, if any.
    public var textDelta: String? {
        guard case .contentBlockDelta(_, .text(let text)) = self else { return nil }
        return text
    }

    /// Decodes a Server-Sent Event of a Messages stream.
    ///
    /// The JSON `type` member selects the case; it matches the SSE event name.
    ///
    /// - Parameter event: An event from the stream.
    /// - Throws: ``LLMStreamError/invalidPayload(event:reason:)`` if the data cannot be decoded.
    public init(decoding event: ServerSentEvent) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: Data(event.data.utf8))
        } catch {
            throw LLMStreamError.invalidPayload(event: event, reason: describeDecodingError(error))
        }
    }

    /// The message metadata sent in `message_start`.
    public struct Message: Sendable, Hashable {
        /// The message ID.
        public var id: String
        /// The model that is generating the response.
        public var model: String
        /// The author role, `assistant`.
        public var role: String
        /// The stop reason, `nil` until a `message_delta` sets it.
        public var stopReason: StopReason?
        /// The stop sequence that ended generation, if any.
        public var stopSequence: String?
        /// The initial usage: input tokens and the first output tokens.
        public var usage: Usage?

        /// Creates message metadata.
        ///
        /// - Parameters:
        ///   - id: The message ID.
        ///   - model: The model.
        ///   - role: The author role. Defaults to `assistant`.
        ///   - stopReason: The stop reason. Defaults to `nil`.
        ///   - stopSequence: The stop sequence. Defaults to `nil`.
        ///   - usage: The initial usage. Defaults to `nil`.
        public init(
            id: String,
            model: String,
            role: String = "assistant",
            stopReason: StopReason? = nil,
            stopSequence: String? = nil,
            usage: Usage? = nil
        ) {
            self.id = id
            self.model = model
            self.role = role
            self.stopReason = stopReason
            self.stopSequence = stopSequence
            self.usage = usage
        }
    }

    /// The initial state of a content block.
    public enum ContentBlock: Sendable, Hashable {
        /// A text block; its text arrives in ``Delta/text(_:)`` deltas.
        case text(String)
        /// A call of a client tool; its input arrives as ``Delta/inputJSON(_:)`` deltas.
        case toolUse(id: String, name: String, input: JSONValue)
        /// A call of a server tool, such as web search, executed by the API.
        case serverToolUse(id: String, name: String, input: JSONValue)
        /// A thinking block; its text arrives in ``Delta/thinking(_:)`` deltas, followed by a
        /// ``Delta/signature(_:)``.
        case thinking(String, signature: String)
        /// A thinking block whose content is encrypted.
        case redactedThinking(data: String)
        /// A block type this package does not model, such as server tool results.
        case other(type: String, payload: JSONValue)
    }

    /// An update of a content block.
    public enum Delta: Sendable, Hashable {
        /// Text to append to a text block.
        case text(String)
        /// A fragment of a tool use block's JSON input.
        case inputJSON(String)
        /// Text to append to a thinking block.
        case thinking(String)
        /// The signature of a thinking block.
        case signature(String)
        /// A citation to attach to a text block.
        case citation(JSONValue)
        /// A delta type this package does not model.
        case other(type: String, payload: JSONValue)
    }

    /// The top-level changes sent in `message_delta`.
    public struct MessageDelta: Sendable, Hashable {
        /// Why generation stopped.
        public var stopReason: StopReason?
        /// The stop sequence that ended generation, if any.
        public var stopSequence: String?
        /// Usage; the counts are cumulative for the whole response.
        public var usage: Usage?

        /// Creates message changes.
        ///
        /// - Parameters:
        ///   - stopReason: The stop reason. Defaults to `nil`.
        ///   - stopSequence: The stop sequence. Defaults to `nil`.
        ///   - usage: The cumulative usage. Defaults to `nil`.
        public init(stopReason: StopReason? = nil, stopSequence: String? = nil, usage: Usage? = nil)
        {
            self.stopReason = stopReason
            self.stopSequence = stopSequence
            self.usage = usage
        }
    }

    /// The reason generation stopped, as an open set of string values.
    public struct StopReason: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
        /// The raw value sent by the API.
        public var rawValue: String

        /// Creates a stop reason from the API's raw value.
        ///
        /// - Parameter rawValue: The raw value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// The model reached a natural stopping point.
        public static let endTurn = StopReason(rawValue: "end_turn")
        /// The `max_tokens` limit was reached.
        public static let maxTokens = StopReason(rawValue: "max_tokens")
        /// One of the custom stop sequences was generated.
        public static let stopSequence = StopReason(rawValue: "stop_sequence")
        /// The model wants to call a tool.
        public static let toolUse = StopReason(rawValue: "tool_use")
        /// A long-running turn was paused and can be continued.
        public static let pauseTurn = StopReason(rawValue: "pause_turn")
        /// The model or a safety classifier declined the request.
        public static let refusal = StopReason(rawValue: "refusal")
        /// The context window was exhausted.
        public static let modelContextWindowExceeded = StopReason(
            rawValue: "model_context_window_exceeded")

        /// The raw value.
        public var description: String { rawValue }
    }

    /// Token usage.
    ///
    /// Every field is optional because events report different subsets.
    public struct Usage: Sendable, Hashable {
        /// Input tokens that were not read from or written to the prompt cache.
        public var inputTokens: Int?
        /// Output tokens.
        public var outputTokens: Int?
        /// Input tokens written to the prompt cache.
        public var cacheCreationInputTokens: Int?
        /// Input tokens read from the prompt cache.
        public var cacheReadInputTokens: Int?

        /// Creates usage counts.
        ///
        /// - Parameters:
        ///   - inputTokens: Uncached input tokens.
        ///   - outputTokens: Output tokens.
        ///   - cacheCreationInputTokens: Input tokens written to the cache.
        ///   - cacheReadInputTokens: Input tokens read from the cache.
        public init(
            inputTokens: Int? = nil,
            outputTokens: Int? = nil,
            cacheCreationInputTokens: Int? = nil,
            cacheReadInputTokens: Int? = nil
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
        }

        /// Returns these counts with every field that `newer` reports replaced by its value.
        ///
        /// - Parameter newer: Later, cumulative counts.
        /// - Returns: The merged counts.
        public func merging(_ newer: Usage) -> Usage {
            Usage(
                inputTokens: newer.inputTokens ?? inputTokens,
                outputTokens: newer.outputTokens ?? outputTokens,
                cacheCreationInputTokens: newer.cacheCreationInputTokens
                    ?? cacheCreationInputTokens,
                cacheReadInputTokens: newer.cacheReadInputTokens ?? cacheReadInputTokens
            )
        }
    }
}

// MARK: - Decoding

extension AnthropicStreamEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case message
        case index
        case contentBlock = "content_block"
        case delta
        case usage
        case error
    }

    private enum MessageDeltaKeys: String, CodingKey {
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }

    /// Decodes an event from its JSON representation.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if the JSON has no `type` or a known type is malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "message_start":
            self = .messageStart(try container.decode(Message.self, forKey: .message))
        case "content_block_start":
            self = .contentBlockStart(
                index: try container.decode(Int.self, forKey: .index),
                block: try container.decode(ContentBlock.self, forKey: .contentBlock))
        case "content_block_delta":
            self = .contentBlockDelta(
                index: try container.decode(Int.self, forKey: .index),
                delta: try container.decode(Delta.self, forKey: .delta))
        case "content_block_stop":
            self = .contentBlockStop(index: try container.decode(Int.self, forKey: .index))
        case "message_delta":
            let delta = try container.nestedContainer(
                keyedBy: MessageDeltaKeys.self, forKey: .delta)
            self = .messageDelta(
                MessageDelta(
                    stopReason: try delta.decodeIfPresent(String.self, forKey: .stopReason)
                        .map(StopReason.init(rawValue:)),
                    stopSequence: try delta.decodeIfPresent(String.self, forKey: .stopSequence),
                    usage: try container.decodeIfPresent(Usage.self, forKey: .usage)))
        case "message_stop":
            self = .messageStop
        case "ping":
            self = .ping
        case "error":
            self = .error(try container.decode(ProviderError.self, forKey: .error))
        default:
            self = .unknown(type: type, payload: try JSONValue(from: decoder))
        }
    }
}

extension AnthropicStreamEvent.Message: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case role
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
    }

    /// Decodes the message of `message_start`.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if a present field has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
            .map(AnthropicStreamEvent.StopReason.init(rawValue:))
        stopSequence = try container.decodeIfPresent(String.self, forKey: .stopSequence)
        usage = try container.decodeIfPresent(AnthropicStreamEvent.Usage.self, forKey: .usage)
    }
}

extension AnthropicStreamEvent.ContentBlock: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case thinking
        case signature
        case data
    }

    /// Decodes a content block, keeping unknown block types as JSON.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if the block has no `type` or a known type is malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "tool_use", "server_tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input =
                try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])
            self =
                type == "tool_use"
                ? .toolUse(id: id, name: name, input: input)
                : .serverToolUse(id: id, name: name, input: input)
        case "thinking":
            self = .thinking(
                try container.decodeIfPresent(String.self, forKey: .thinking) ?? "",
                signature: try container.decodeIfPresent(String.self, forKey: .signature) ?? "")
        case "redacted_thinking":
            self = .redactedThinking(data: try container.decode(String.self, forKey: .data))
        default:
            self = .other(type: type, payload: try JSONValue(from: decoder))
        }
    }
}

extension AnthropicStreamEvent.Delta: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case partialJSON = "partial_json"
        case thinking
        case signature
        case citation
    }

    /// Decodes a delta, keeping unknown delta types as JSON.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if the delta has no `type` or a known type is malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text_delta":
            self = .text(try container.decode(String.self, forKey: .text))
        case "input_json_delta":
            self = .inputJSON(try container.decode(String.self, forKey: .partialJSON))
        case "thinking_delta":
            self = .thinking(try container.decode(String.self, forKey: .thinking))
        case "signature_delta":
            self = .signature(try container.decode(String.self, forKey: .signature))
        case "citations_delta":
            self = .citation(try container.decode(JSONValue.self, forKey: .citation))
        default:
            self = .other(type: type, payload: try JSONValue(from: decoder))
        }
    }
}

extension AnthropicStreamEvent.Usage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    /// Decodes usage; absent and `null` counts are `nil`.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if a present count is not an integer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens),
            outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens),
            cacheCreationInputTokens: try container.decodeIfPresent(
                Int.self, forKey: .cacheCreationInputTokens),
            cacheReadInputTokens: try container.decodeIfPresent(
                Int.self, forKey: .cacheReadInputTokens)
        )
    }
}
