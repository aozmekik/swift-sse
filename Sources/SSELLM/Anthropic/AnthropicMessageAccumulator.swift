import Foundation

/// Assembles the events of an Anthropic Messages stream into a complete message.
///
/// ```swift
/// var message = AnthropicMessageAccumulator()
/// for try await event in EventSource(request: request).anthropicStreamEvents() {
///     try message.add(event)
/// }
/// print(message.text, message.stopReason?.rawValue ?? "none")
/// ```
///
/// Deltas for a block index that has not been started are ignored; the API always starts a block
/// before it sends deltas for it.
public struct AnthropicMessageAccumulator: Sendable {
    /// The message ID, from `message_start`.
    public private(set) var id: String?
    /// The model, from `message_start`.
    public private(set) var model: String?
    /// Why generation stopped, from the last `message_delta` that set it.
    public private(set) var stopReason: AnthropicStreamEvent.StopReason?
    /// The stop sequence that ended generation, if any.
    public private(set) var stopSequence: String?
    /// Usage, merged from `message_start` and the cumulative counts of `message_delta`.
    public private(set) var usage = AnthropicStreamEvent.Usage()
    /// Whether `message_stop` has been received.
    public private(set) var isComplete = false

    private var blocksByIndex: [Int: Block] = [:]

    /// Creates an empty accumulator.
    public init() {}

    /// The content blocks so far, ordered by index.
    public var content: [Block] {
        blocksByIndex.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The concatenated text of all text blocks so far.
    public var text: String {
        content.reduce(into: "") { text, block in
            if case .text(let blockText) = block {
                text += blockText
            }
        }
    }

    /// The client tool calls so far, in block order.
    public var toolUses: [ToolUse] {
        content.compactMap { block in
            guard case .toolUse(let toolUse) = block, !toolUse.isServerTool else { return nil }
            return toolUse
        }
    }

    /// Adds the next event of the stream.
    ///
    /// - Parameter event: An event, in stream order.
    /// - Throws: ``LLMStreamError/provider(_:)`` for an `error` event.
    public mutating func add(_ event: AnthropicStreamEvent) throws {
        switch event {
        case .messageStart(let message):
            id = message.id
            model = message.model
            stopReason = message.stopReason
            stopSequence = message.stopSequence
            if let messageUsage = message.usage {
                usage = usage.merging(messageUsage)
            }
        case .contentBlockStart(let index, let block):
            blocksByIndex[index] = Block(block)
        case .contentBlockDelta(let index, let delta):
            blocksByIndex[index]?.apply(delta)
        case .contentBlockStop:
            break
        case .messageDelta(let delta):
            if let reason = delta.stopReason {
                stopReason = reason
            }
            if let sequence = delta.stopSequence {
                stopSequence = sequence
            }
            if let deltaUsage = delta.usage {
                usage = usage.merging(deltaUsage)
            }
        case .messageStop:
            isComplete = true
        case .ping, .unknown:
            break
        case .error(let error):
            throw LLMStreamError.provider(error)
        }
    }

    /// A content block assembled from its start event and deltas.
    public enum Block: Sendable, Hashable {
        /// A text block.
        case text(String)
        /// A tool call, of a client tool or of a server tool.
        case toolUse(ToolUse)
        /// A thinking block and its signature.
        case thinking(String, signature: String)
        /// An encrypted thinking block.
        case redactedThinking(data: String)
        /// A block type this package does not model, as sent in `content_block_start`.
        case other(type: String, payload: JSONValue)

        init(_ block: AnthropicStreamEvent.ContentBlock) {
            switch block {
            case .text(let text):
                self = .text(text)
            case .toolUse(let id, let name, let input):
                self = .toolUse(
                    ToolUse(id: id, name: name, isServerTool: false, initialInput: input))
            case .serverToolUse(let id, let name, let input):
                self = .toolUse(
                    ToolUse(id: id, name: name, isServerTool: true, initialInput: input))
            case .thinking(let thinking, let signature):
                self = .thinking(thinking, signature: signature)
            case .redactedThinking(let data):
                self = .redactedThinking(data: data)
            case .other(let type, let payload):
                self = .other(type: type, payload: payload)
            }
        }

        /// Appends `delta` to the block in place.
        ///
        /// Each case takes the payload out and replaces `self` with a placeholder before
        /// appending, so that the payload's storage is uniquely referenced and grows in place;
        /// rebuilding the case from `text + fragment` would copy the whole text on every delta.
        mutating func apply(_ delta: AnthropicStreamEvent.Delta) {
            switch delta {
            case .text(let fragment):
                guard case .text(var text) = self else { return }
                self = .placeholder
                text += fragment
                self = .text(text)
            case .inputJSON(let fragment):
                guard case .toolUse(var toolUse) = self else { return }
                self = .placeholder
                toolUse.inputJSON += fragment
                self = .toolUse(toolUse)
            case .thinking(let fragment):
                guard case .thinking(var thinking, let signature) = self else { return }
                self = .placeholder
                thinking += fragment
                self = .thinking(thinking, signature: signature)
            case .signature(let fragment):
                guard case .thinking(let thinking, var signature) = self else { return }
                self = .placeholder
                signature += fragment
                self = .thinking(thinking, signature: signature)
            case .citation, .other:
                break  // Citations and unmodeled deltas are available from the events.
            }
        }

        /// A value that holds no storage, assigned while a payload is being extended.
        private static let placeholder = Block.redactedThinking(data: "")
    }

    /// A tool call assembled from `content_block_start` and its `input_json_delta` fragments.
    public struct ToolUse: Sendable, Hashable {
        /// The tool use ID, to send back with the tool result.
        public var id: String
        /// The tool name.
        public var name: String
        /// Whether this is a server tool (such as web search) that the API executes itself.
        public var isServerTool: Bool
        /// The JSON input fragments concatenated so far.
        ///
        /// Empty if the input arrived complete in `content_block_start`.
        public var inputJSON = ""

        private var initialInput: JSONValue

        init(id: String, name: String, isServerTool: Bool, initialInput: JSONValue) {
            self.id = id
            self.name = name
            self.isServerTool = isServerTool
            self.initialInput = initialInput
        }

        /// The complete input as JSON.
        ///
        /// - Throws: `DecodingError` if the streamed input is not valid JSON, for example
        ///   because the stream was cut off.
        public var input: JSONValue {
            get throws {
                try decodeInput(as: JSONValue.self)
            }
        }

        /// Decodes the complete input.
        ///
        /// - Parameter type: The type to decode the input as.
        /// - Returns: The decoded input.
        /// - Throws: `DecodingError` if the input is not valid JSON for `type`.
        public func decodeInput<Input: Decodable>(
            as type: Input.Type = Input.self
        ) throws -> Input {
            let data =
                inputJSON.isEmpty
                ? try JSONEncoder().encode(initialInput)
                : Data(inputJSON.utf8)
            return try JSONDecoder().decode(type, from: data)
        }
    }
}
