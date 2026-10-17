import SSE

extension AsyncSequence where Element == ServerSentEvent {
    /// Decodes an OpenAI-compatible Chat Completions stream into its chunks.
    ///
    /// The sequence ends at `data: [DONE]` without reading further, throws
    /// ``LLMStreamError/provider(_:)`` for an error payload, and throws
    /// ``LLMStreamError/truncated`` if the events end before `[DONE]`. Events whose type is not
    /// `message` or `error` (some proxies add their own) are skipped.
    ///
    /// ```swift
    /// for try await chunk in EventSource(request: request).openAIChatCompletionChunks() {
    ///     print(chunk.textDelta ?? "", terminator: "")
    /// }
    /// ```
    ///
    /// - Returns: An asynchronous sequence of chunks.
    public func openAIChatCompletionChunks() -> OpenAIChatCompletionChunkSequence<Self> {
        OpenAIChatCompletionChunkSequence(base: self)
    }

    /// Decodes an Anthropic Messages stream into its events.
    ///
    /// The sequence yields every event up to and including `message_stop`, then ends without
    /// reading further. It throws ``LLMStreamError/provider(_:)`` for an `error` event and
    /// ``LLMStreamError/truncated`` if the events end before `message_stop`.
    ///
    /// ```swift
    /// for try await event in EventSource(request: request).anthropicStreamEvents() {
    ///     print(event.textDelta ?? "", terminator: "")
    /// }
    /// ```
    ///
    /// - Returns: An asynchronous sequence of decoded events.
    public func anthropicStreamEvents() -> AnthropicStreamEventSequence<Self> {
        AnthropicStreamEventSequence(base: self)
    }
}

/// The chunks of an OpenAI-compatible Chat Completions stream.
///
/// Create one with `openAIChatCompletionChunks()`.
public struct OpenAIChatCompletionChunkSequence<Base: AsyncSequence>: AsyncSequence
where Base.Element == ServerSentEvent {
    /// The decoded chunks.
    public typealias Element = OpenAIChatCompletionChunk

    private let base: Base

    init(base: Base) {
        self.base = base
    }

    /// Creates an iterator over the chunks.
    ///
    /// - Returns: An iterator that reads the base sequence's events on demand.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }

    /// The iterator of an ``OpenAIChatCompletionChunkSequence``.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var base: Base.AsyncIterator
        private var isFinished = false

        init(base: Base.AsyncIterator) {
            self.base = base
        }

        /// Returns the next chunk.
        ///
        /// - Returns: The next chunk, or `nil` after `[DONE]`.
        /// - Throws: ``LLMStreamError``, or any error of the base sequence.
        public mutating func next() async throws -> OpenAIChatCompletionChunk? {
            guard !isFinished else { return nil }
            do {
                while true {
                    guard let event = try await base.next() else {
                        throw LLMStreamError.truncated
                    }
                    guard event.type == ServerSentEvent.defaultType || event.type == "error" else {
                        continue
                    }
                    switch try OpenAIChatStreamEvent(decoding: event) {
                    case .chunk(let chunk):
                        return chunk
                    case .done:
                        isFinished = true
                        return nil
                    case .error(let error):
                        throw LLMStreamError.provider(error)
                    }
                }
            } catch {
                isFinished = true
                throw error
            }
        }
    }
}

/// The events of an Anthropic Messages stream.
///
/// Create one with `anthropicStreamEvents()`.
public struct AnthropicStreamEventSequence<Base: AsyncSequence>: AsyncSequence
where Base.Element == ServerSentEvent {
    /// The decoded events.
    public typealias Element = AnthropicStreamEvent

    private let base: Base

    init(base: Base) {
        self.base = base
    }

    /// Creates an iterator over the events.
    ///
    /// - Returns: An iterator that reads the base sequence's events on demand.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }

    /// The iterator of an ``AnthropicStreamEventSequence``.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var base: Base.AsyncIterator
        private var isFinished = false

        init(base: Base.AsyncIterator) {
            self.base = base
        }

        /// Returns the next event.
        ///
        /// - Returns: The next event, or `nil` after `message_stop`.
        /// - Throws: ``LLMStreamError``, or any error of the base sequence.
        public mutating func next() async throws -> AnthropicStreamEvent? {
            guard !isFinished else { return nil }
            do {
                guard let event = try await base.next() else {
                    throw LLMStreamError.truncated
                }
                let decoded = try AnthropicStreamEvent(decoding: event)
                switch decoded {
                case .error(let error):
                    throw LLMStreamError.provider(error)
                case .messageStop:
                    isFinished = true
                default:
                    break
                }
                return decoded
            } catch {
                isFinished = true
                throw error
            }
        }
    }
}

extension OpenAIChatCompletionChunkSequence: Sendable where Base: Sendable {}
extension AnthropicStreamEventSequence: Sendable where Base: Sendable {}
