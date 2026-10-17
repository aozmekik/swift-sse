/// An arbitrary JSON value, for the parts of LLM streams that have no fixed schema.
///
/// Tool inputs, citations and content blocks of types this package does not model are kept as
/// `JSONValue`, so nothing the provider sent is lost.
public enum JSONValue: Sendable, Hashable {
    /// `null`.
    case null
    /// `true` or `false`.
    case bool(Bool)
    /// A number. JSON does not distinguish integers from floating-point numbers.
    case number(Double)
    /// A string.
    case string(String)
    /// An array.
    case array([JSONValue])
    /// An object.
    case object([String: JSONValue])

    /// The value of `key` if this is an object that contains it.
    ///
    /// - Parameter key: The object key.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    /// The string, if this is a string.
    public var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    /// The number, if this is a number.
    public var numberValue: Double? {
        guard case .number(let number) = self else { return nil }
        return number
    }

    /// The Boolean, if this is a Boolean.
    public var boolValue: Bool? {
        guard case .bool(let bool) = self else { return nil }
        return bool
    }
}

extension JSONValue: Codable {
    /// Decodes any JSON value.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` if the input is not JSON.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a JSON value")
        }
    }

    /// Encodes the value as JSON.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: `EncodingError` if a number is not finite.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .number(let number):
            try container.encode(number)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}
