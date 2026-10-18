import Foundation

/// Assembles the chunks of an OpenAI-compatible Chat Completions stream into complete messages.
///
/// ```swift
/// var completion = OpenAIChatCompletionAccumulator()
/// for try await chunk in EventSource(request: request).openAIChatCompletionChunks() {
///     completion.add(chunk)
/// }
/// print(completion.text)
/// for call in completion.choices.first?.toolCalls ?? [] {
///     let arguments = try call.decodeArguments(as: WeatherQuery.self)
/// }
/// ```
///
/// Text, refusal and tool call arguments are concatenated. A tool call's ID, type and name are
/// taken from the first fragment that carries them, so servers that repeat them in every fragment
/// are handled too.
///
/// Fragments are grouped into calls by their `index`. Some OpenAI-compatible servers omit it and
/// send each call whole or as consecutive fragments; a fragment without an index then continues
/// the most recently started call, unless it carries a different call ID or is not the first
/// tool call fragment of its chunk, in which case it starts a new call.
public struct OpenAIChatCompletionAccumulator: Sendable {
    /// The completion ID, from the first chunk that carried one.
    public private(set) var id: String?
    /// The model, from the first chunk that carried one.
    public private(set) var model: String?
    /// Token usage, if the server sent it.
    public private(set) var usage: OpenAIChatCompletionChunk.Usage?

    private var choicesByIndex: [Int: Choice] = [:]

    /// Creates an empty accumulator.
    public init() {}

    /// The assembled choices, ordered by index.
    public var choices: [Choice] {
        choicesByIndex.values.sorted { $0.index < $1.index }
    }

    /// The text of the first choice (index 0) so far.
    public var text: String {
        choicesByIndex[0]?.content ?? ""
    }

    /// Adds the next chunk of the stream.
    ///
    /// - Parameter chunk: A chunk, in stream order.
    public mutating func add(_ chunk: OpenAIChatCompletionChunk) {
        if id == nil {
            id = chunk.id
        }
        if model == nil {
            model = chunk.model
        }
        if let chunkUsage = chunk.usage {
            usage = chunkUsage
        }
        for update in chunk.choices {
            // Mutated in place: copying the choice out and back would copy its text on every
            // delta, which makes accumulation quadratic in the length of the response.
            choicesByIndex[update.index, default: Choice(index: update.index)].apply(update)
        }
    }

    /// A choice assembled from its fragments.
    public struct Choice: Sendable, Hashable {
        /// The index of the choice.
        public var index: Int
        /// The author role, usually `assistant`.
        public var role: String?
        /// The message text.
        public var content = ""
        /// The refusal message, if the model refused.
        public var refusal: String?
        /// The tool calls, ordered by index.
        public var toolCalls: [ToolCall] = []
        /// Why generation stopped, once the choice is complete.
        public var finishReason: OpenAIChatCompletionChunk.FinishReason?

        init(index: Int) {
            self.index = index
        }

        mutating func apply(_ update: OpenAIChatCompletionChunk.Choice) {
            if role == nil {
                role = update.delta.role
            }
            content += update.delta.content ?? ""
            if let fragment = update.delta.refusal {
                if refusal == nil {
                    refusal = fragment
                } else {
                    refusal?.append(fragment)
                }
            }
            for (position, fragment) in update.delta.toolCalls.enumerated() {
                let index = fragment.index ?? inferredIndex(of: fragment, isFirst: position == 0)
                if let existing = toolCalls.firstIndex(where: { $0.index == index }) {
                    toolCalls[existing].apply(fragment)
                } else {
                    var call = ToolCall(index: index)
                    call.apply(fragment)
                    toolCalls.append(call)
                    toolCalls.sort { $0.index < $1.index }
                }
            }
            if let reason = update.finishReason {
                finishReason = reason
            }
        }

        /// The call that a fragment without an `index` belongs to.
        ///
        /// Without indices, calls start in order, so the most recently started call is the one
        /// with the largest index.
        private func inferredIndex(
            of fragment: OpenAIChatCompletionChunk.ToolCallDelta,
            isFirst: Bool
        ) -> Int {
            guard let last = toolCalls.last else { return 0 }
            let continuesLast: Bool
            if let id = fragment.id, let lastID = last.id {
                continuesLast = id == lastID
            } else {
                continuesLast = isFirst && fragment.id == nil
            }
            return continuesLast ? last.index : last.index + 1
        }
    }

    /// A tool call assembled from its fragments.
    public struct ToolCall: Sendable, Hashable {
        /// The position of the call in the message: the server's `index`, or the order in which
        /// the calls started for servers that omit it.
        public var index: Int
        /// The tool call ID, to send back with the tool result.
        public var id: String?
        /// The tool type, `function` for OpenAI.
        public var type: String?
        /// The function name.
        public var name = ""
        /// The JSON-encoded arguments, as concatenated so far.
        public var arguments = ""

        init(index: Int) {
            self.index = index
        }

        mutating func apply(_ fragment: OpenAIChatCompletionChunk.ToolCallDelta) {
            if id == nil {
                id = fragment.id
            }
            if type == nil {
                type = fragment.type
            }
            if name.isEmpty, let fragmentName = fragment.function?.name {
                name = fragmentName
            }
            arguments += fragment.function?.arguments ?? ""
        }

        /// Decodes the complete arguments.
        ///
        /// - Parameter type: The type to decode the arguments as.
        /// - Returns: The decoded arguments.
        /// - Throws: `DecodingError` if the arguments are not valid JSON for `type`, for example
        ///   because the stream was cut off.
        public func decodeArguments<Arguments: Decodable>(
            as type: Arguments.Type = Arguments.self
        ) throws -> Arguments {
            try JSONDecoder().decode(type, from: Data(arguments.utf8))
        }
    }
}
