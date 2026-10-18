/// An arbitrary JSON value, for the parts of LLM streams that have no fixed schema.
///
/// Tool inputs, citations and content blocks of types this package does not model are kept as
/// `JSONValue`, so that unmodeled fields stay available.
///
/// Numbers keep their value exactly when they are integers in the range of `Int64`, which covers
/// the large numeric IDs that a `Double` would round (it is exact only up to 2⁵³). Other numbers
/// are stored as the nearest `Double`: numbers with a fractional part, and integers outside the
/// range of `Int64`, which therefore can lose precision. Values compare by case, so
/// `.integer(1)` and `.number(1)` are different values although they encode to the same JSON.
public enum JSONValue: Sendable, Hashable {
    /// `null`.
    case null
    /// `true` or `false`.
    case bool(Bool)
    /// An integer in the range of `Int64`, kept exactly.
    ///
    /// Decoding produces this case for every number with an integral value in that range, also
    /// when it is written as `1.0` or `1e3`.
    case integer(Int64)
    /// Any other number, as the nearest `Double`.
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

    /// The number as a `Double`, if this is a number.
    ///
    /// An ``integer(_:)`` beyond 2⁵³ in magnitude is rounded to the nearest `Double`.
    public var numberValue: Double? {
        switch self {
        case .integer(let integer): Double(integer)
        case .number(let number): number
        default: nil
        }
    }

    /// The number as an `Int64`, if this is an integer or a number with an integral value that
    /// `Int64` represents exactly.
    public var integerValue: Int64? {
        switch self {
        case .integer(let integer): integer
        case .number(let number): Int64(exactly: number)
        default: nil
        }
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
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
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
        case .integer(let integer):
            try container.encode(integer)
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
