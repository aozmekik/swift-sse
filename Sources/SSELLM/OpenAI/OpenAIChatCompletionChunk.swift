/// One `chat.completion.chunk` object of an OpenAI-compatible Chat Completions stream.
///
/// Decoding is lenient where OpenAI-compatible servers differ: metadata fields are optional,
/// missing collections decode as empty, and unknown fields are ignored. See
/// <https://platform.openai.com/docs/api-reference/chat-streaming> for the format.
public struct OpenAIChatCompletionChunk: Sendable, Hashable {
    /// The completion ID, shared by every chunk of a response.
    public var id: String?
    /// The object type, `chat.completion.chunk` for OpenAI.
    public var object: String?
    /// The Unix timestamp (in seconds) of the completion's creation.
    public var created: Int?
    /// The model that generated the completion.
    public var model: String?
    /// The backend configuration fingerprint, if the server sends one.
    public var systemFingerprint: String?
    /// The service tier that processed the request, if the server reports it.
    public var serviceTier: String?
    /// The incremental updates, one per choice.
    ///
    /// Empty in a final usage-only chunk.
    public var choices: [Choice]
    /// Token usage; sent in a final chunk when `stream_options.include_usage` is set.
    public var usage: Usage?

    /// Creates a chunk, for example to test code that consumes chunks.
    ///
    /// - Parameters:
    ///   - id: The completion ID.
    ///   - object: The object type. Defaults to `chat.completion.chunk`.
    ///   - created: The creation timestamp. Defaults to `nil`.
    ///   - model: The model. Defaults to `nil`.
    ///   - systemFingerprint: The backend fingerprint. Defaults to `nil`.
    ///   - serviceTier: The service tier. Defaults to `nil`.
    ///   - choices: The choice updates. Defaults to none.
    ///   - usage: The token usage. Defaults to `nil`.
    public init(
        id: String? = nil,
        object: String? = "chat.completion.chunk",
        created: Int? = nil,
        model: String? = nil,
        systemFingerprint: String? = nil,
        serviceTier: String? = nil,
        choices: [Choice] = [],
        usage: Usage? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.systemFingerprint = systemFingerprint
        self.serviceTier = serviceTier
        self.choices = choices
        self.usage = usage
    }

    /// The text that this chunk adds to the first choice (index 0), if any.
    public var textDelta: String? {
        choices.first { $0.index == 0 }?.delta.content
    }

    /// An incremental update of one choice.
    public struct Choice: Sendable, Hashable {
        /// The index of the choice; a request with `n > 1` streams several choices.
        public var index: Int
        /// What this chunk adds to the choice.
        public var delta: Delta
        /// Why generation stopped; set only in the choice's last chunk.
        public var finishReason: FinishReason?

        /// Creates a choice update.
        ///
        /// - Parameters:
        ///   - index: The index of the choice. Defaults to 0.
        ///   - delta: What the chunk adds. Defaults to nothing.
        ///   - finishReason: Why generation stopped. Defaults to `nil`.
        public init(index: Int = 0, delta: Delta = Delta(), finishReason: FinishReason? = nil) {
            self.index = index
            self.delta = delta
            self.finishReason = finishReason
        }
    }

    /// What a chunk adds to a choice's message.
    public struct Delta: Sendable, Hashable {
        /// The author role, usually sent only in the first chunk.
        public var role: String?
        /// A fragment of the message text.
        public var content: String?
        /// A fragment of a refusal message.
        public var refusal: String?
        /// Fragments of tool calls, identified by their ``ToolCallDelta/index``.
        public var toolCalls: [ToolCallDelta]

        /// Creates a delta.
        ///
        /// - Parameters:
        ///   - role: The author role. Defaults to `nil`.
        ///   - content: A text fragment. Defaults to `nil`.
        ///   - refusal: A refusal fragment. Defaults to `nil`.
        ///   - toolCalls: Tool call fragments. Defaults to none.
        public init(
            role: String? = nil,
            content: String? = nil,
            refusal: String? = nil,
            toolCalls: [ToolCallDelta] = []
        ) {
            self.role = role
            self.content = content
            self.refusal = refusal
            self.toolCalls = toolCalls
        }
    }

    /// A fragment of a tool call.
    public struct ToolCallDelta: Sendable, Hashable {
        /// The position of the tool call in the message; fragments with the same index belong to
        /// the same call.
        public var index: Int
        /// The tool call ID, usually sent only in the call's first fragment.
        public var id: String?
        /// The tool type, `function` for OpenAI.
        public var type: String?
        /// The function name and a fragment of its JSON arguments.
        public var function: FunctionDelta?

        /// Creates a tool call fragment.
        ///
        /// - Parameters:
        ///   - index: The position of the call.
        ///   - id: The tool call ID. Defaults to `nil`.
        ///   - type: The tool type. Defaults to `nil`.
        ///   - function: The function fragment. Defaults to `nil`.
        public init(
            index: Int,
            id: String? = nil,
            type: String? = nil,
            function: FunctionDelta? = nil
        ) {
            self.index = index
            self.id = id
            self.type = type
            self.function = function
        }
    }

    /// A fragment of a function call.
    public struct FunctionDelta: Sendable, Hashable {
        /// The function name, usually sent only in the call's first fragment.
        public var name: String?
        /// A fragment of the JSON-encoded arguments.
        public var arguments: String?

        /// Creates a function call fragment.
        ///
        /// - Parameters:
        ///   - name: The function name. Defaults to `nil`.
        ///   - arguments: A fragment of the arguments. Defaults to `nil`.
        public init(name: String? = nil, arguments: String? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// The reason a choice stopped, as an open set of string values.
    public struct FinishReason: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
        /// The raw value sent by the server.
        public var rawValue: String

        /// Creates a finish reason from the server's raw value.
        ///
        /// - Parameter rawValue: The raw value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// The model reached a natural stopping point or a stop sequence.
        public static let stop = FinishReason(rawValue: "stop")
        /// The token limit was reached.
        public static let length = FinishReason(rawValue: "length")
        /// The model called one or more tools.
        public static let toolCalls = FinishReason(rawValue: "tool_calls")
        /// Content was omitted by a content filter.
        public static let contentFilter = FinishReason(rawValue: "content_filter")
        /// The model called a function (deprecated `functions` API).
        public static let functionCall = FinishReason(rawValue: "function_call")

        /// The raw value.
        public var description: String { rawValue }
    }

    /// Token usage of a completion.
    public struct Usage: Sendable, Hashable {
        /// Tokens in the prompt; 0 if the server omits the field.
        public var promptTokens: Int
        /// Tokens in the completion; 0 if the server omits the field.
        public var completionTokens: Int
        /// Total tokens; 0 if the server omits the field.
        public var totalTokens: Int
        /// Prompt tokens served from the prompt cache, if reported.
        public var cachedPromptTokens: Int?
        /// Completion tokens spent on reasoning, if reported.
        public var reasoningTokens: Int?

        /// Creates usage counts.
        ///
        /// - Parameters:
        ///   - promptTokens: Tokens in the prompt.
        ///   - completionTokens: Tokens in the completion.
        ///   - totalTokens: Total tokens.
        ///   - cachedPromptTokens: Cached prompt tokens. Defaults to `nil`.
        ///   - reasoningTokens: Reasoning tokens. Defaults to `nil`.
        public init(
            promptTokens: Int,
            completionTokens: Int,
            totalTokens: Int,
            cachedPromptTokens: Int? = nil,
            reasoningTokens: Int? = nil
        ) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
            self.cachedPromptTokens = cachedPromptTokens
            self.reasoningTokens = reasoningTokens
        }
    }
}

// MARK: - Decoding

extension OpenAIChatCompletionChunk: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case model
        case systemFingerprint = "system_fingerprint"
        case serviceTier = "service_tier"
        case choices
        case usage
    }

    /// Decodes a chunk from its JSON representation.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if a present field has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        created = try container.decodeIfPresent(Int.self, forKey: .created)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        systemFingerprint = try container.decodeIfPresent(String.self, forKey: .systemFingerprint)
        serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
        choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
    }
}

extension OpenAIChatCompletionChunk.Choice: Decodable {
    private enum CodingKeys: String, CodingKey {
        case index
        case delta
        case finishReason = "finish_reason"
    }

    /// Decodes a choice; a missing `index` is 0 and a missing `delta` is empty.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if a present field has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        delta =
            try container.decodeIfPresent(OpenAIChatCompletionChunk.Delta.self, forKey: .delta)
            ?? OpenAIChatCompletionChunk.Delta()
        finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
            .map(OpenAIChatCompletionChunk.FinishReason.init(rawValue:))
    }
}

extension OpenAIChatCompletionChunk.Delta: Decodable {
    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case refusal
        case toolCalls = "tool_calls"
    }

    /// Decodes a delta; a missing or `null` `tool_calls` is empty.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if a present field has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        refusal = try container.decodeIfPresent(String.self, forKey: .refusal)
        toolCalls =
            try container.decodeIfPresent(
                [OpenAIChatCompletionChunk.ToolCallDelta].self, forKey: .toolCalls) ?? []
    }
}

extension OpenAIChatCompletionChunk.ToolCallDelta: Decodable {
    private enum CodingKeys: String, CodingKey {
        case index
        case id
        case type
        case function
    }

    /// Decodes a tool call fragment; a missing `index` is 0.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if a present field has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        id = try container.decodeIfPresent(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        function = try container.decodeIfPresent(
            OpenAIChatCompletionChunk.FunctionDelta.self, forKey: .function)
    }
}

extension OpenAIChatCompletionChunk.FunctionDelta: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    /// Decodes a function call fragment.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if a present field has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments)
    }
}

extension OpenAIChatCompletionChunk.Usage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
    }

    private enum DetailKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
        case reasoningTokens = "reasoning_tokens"
    }

    /// Decodes usage, flattening the cached and reasoning token details.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if a present field has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        cachedPromptTokens = try Self.detail(.cachedTokens, in: .promptTokensDetails, of: container)
        reasoningTokens = try Self.detail(
            .reasoningTokens, in: .completionTokensDetails, of: container)
    }

    private static func detail(
        _ key: DetailKeys,
        in details: CodingKeys,
        of container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int? {
        guard container.contains(details), try !container.decodeNil(forKey: details) else {
            return nil
        }
        let nested = try container.nestedContainer(keyedBy: DetailKeys.self, forKey: details)
        return try nested.decodeIfPresent(Int.self, forKey: key)
    }
}
