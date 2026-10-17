import Foundation
import SSE

/// One decoded event of an OpenAI-compatible Chat Completions stream.
///
/// ```swift
/// for try await event in EventSource(request: request) {
///     switch try OpenAIChatStreamEvent(decoding: event) {
///     case .chunk(let chunk): print(chunk.textDelta ?? "", terminator: "")
///     case .done: return
///     case .error(let error): throw LLMStreamError.provider(error)
///     }
/// }
/// ```
///
/// Most code can use ``_Concurrency/AsyncSequence/openAIChatCompletionChunks()`` instead, which
/// does this loop and stops at `[DONE]`.
public enum OpenAIChatStreamEvent: Sendable, Hashable {
    /// A `chat.completion.chunk`.
    case chunk(OpenAIChatCompletionChunk)
    /// The `data: [DONE]` sentinel that ends the stream.
    case done
    /// An error payload sent inside the stream, as some OpenAI-compatible servers do.
    case error(ProviderError)

    /// Decodes a Server-Sent Event of a Chat Completions stream.
    ///
    /// The data `[DONE]` decodes as ``done``; a JSON object with a top-level `error` member (or
    /// any payload of an `event: error` event) decodes as ``error(_:)``; anything else must be a
    /// `chat.completion.chunk`.
    ///
    /// - Parameter event: An event from the stream.
    /// - Throws: ``LLMStreamError/invalidPayload(event:reason:)`` if the data cannot be decoded.
    public init(decoding event: ServerSentEvent) throws {
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            self = .done
            return
        }
        let data = Data(event.data.utf8)
        if event.type == "error" {
            self = .error(Self.providerError(in: data, raw: event.data))
            return
        }
        do {
            switch try JSONDecoder().decode(Envelope.self, from: data) {
            case .chunk(let chunk):
                self = .chunk(chunk)
            case .error(let error):
                self = .error(error)
            }
        } catch {
            throw LLMStreamError.invalidPayload(event: event, reason: describeDecodingError(error))
        }
    }

    /// The error in an `event: error` payload: `{"error": {...}}`, a bare error object, or text.
    private static func providerError(in data: Data, raw: String) -> ProviderError {
        if case .error(let error)? = try? JSONDecoder().decode(Envelope.self, from: data) {
            return error
        }
        if let error = try? JSONDecoder().decode(ProviderError.self, from: data),
            !error.message.isEmpty
        {
            return error
        }
        return ProviderError(message: raw)
    }
}

/// A chunk, or a payload with a top-level `error` member.
private enum Envelope: Decodable {
    case chunk(OpenAIChatCompletionChunk)
    case error(ProviderError)

    private enum CodingKeys: String, CodingKey {
        case error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.error), try !container.decodeNil(forKey: .error) {
            self = .error(try container.decode(ProviderError.self, forKey: .error))
        } else {
            self = .chunk(try OpenAIChatCompletionChunk(from: decoder))
        }
    }
}
