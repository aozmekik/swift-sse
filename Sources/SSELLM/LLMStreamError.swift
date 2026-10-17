import SSE

/// An error reported by an LLM API inside a stream whose HTTP status was 200 OK.
///
/// Anthropic sends these as `event: error` (for example `overloaded_error`); OpenAI-compatible
/// servers send a `data:` payload with a top-level `error` object.
public struct ProviderError: Error, Sendable, Hashable {
    /// The provider's error type, such as `overloaded_error`, if it sent one.
    public var type: String?
    /// The human-readable message.
    public var message: String
    /// The provider's error code, if it sent one.
    ///
    /// Numeric codes are converted to strings.
    public var code: String?

    /// Creates a provider error.
    ///
    /// - Parameters:
    ///   - type: The provider's error type.
    ///   - message: The human-readable message.
    ///   - code: The provider's error code.
    public init(type: String? = nil, message: String, code: String? = nil) {
        self.type = type
        self.message = message
        self.code = code
    }
}

extension ProviderError: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case message
        case code
    }

    /// Decodes `{"type": ..., "message": ..., "code": ...}`; every field is optional.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if the value is not an object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
        if let code = try? container.decodeIfPresent(String.self, forKey: .code) {
            self.code = code
        } else if let code = try? container.decodeIfPresent(Int.self, forKey: .code) {
            self.code = String(code)
        } else {
            code = nil
        }
    }
}

extension ProviderError: CustomStringConvertible {
    /// The type, code and message, for logging.
    public var description: String {
        let qualifiers = [type, code.map { "code \($0)" }].compactMap { $0 }
        let prefix = qualifiers.isEmpty ? "" : "[\(qualifiers.joined(separator: ", "))] "
        return prefix + message
    }
}

/// An error that ends a decoded LLM stream.
public enum LLMStreamError: Error, Sendable, Hashable {
    /// The provider reported an error inside the stream.
    ///
    /// - Parameter error: The provider's error.
    case provider(ProviderError)

    /// The stream ended before the provider's terminal event (`data: [DONE]` for OpenAI,
    /// `message_stop` for Anthropic), so the response is incomplete.
    case truncated

    /// An event's data could not be decoded.
    ///
    /// - Parameters:
    ///   - event: The event that failed to decode.
    ///   - reason: A description of the decoding failure.
    case invalidPayload(event: ServerSentEvent, reason: String)
}

extension LLMStreamError: CustomStringConvertible {
    /// A human-readable description of the error.
    public var description: String {
        switch self {
        case .provider(let error):
            return "The provider reported an error: \(error)"
        case .truncated:
            return "The stream ended before its terminal event; the response is incomplete"
        case .invalidPayload(let event, let reason):
            return "Could not decode the '\(event.type)' event: \(reason)"
        }
    }
}

/// Describes a decoding error briefly, with the coding path where it happened.
func describeDecodingError(_ error: any Error) -> String {
    guard let error = error as? DecodingError else { return String(describing: error) }
    func path(_ context: DecodingError.Context) -> String {
        let components = context.codingPath.map { key in
            key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
        }
        return components.isEmpty ? "the top level" : components.joined()
    }
    switch error {
    case .typeMismatch(let type, let context):
        return "expected \(type) at \(path(context)): \(context.debugDescription)"
    case .valueNotFound(let type, let context):
        return "missing \(type) at \(path(context))"
    case .keyNotFound(let key, let context):
        return "missing key '\(key.stringValue)' at \(path(context))"
    case .dataCorrupted(let context):
        return "invalid JSON at \(path(context)): \(context.debugDescription)"
    @unknown default:
        return String(describing: error)
    }
}
