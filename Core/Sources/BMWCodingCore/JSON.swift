import Foundation

/// A JSON value: what the Messages API is sent and answers with, and what the mechanic's tools take and return, as
/// one type, so that no request is put together from strings and equal values always make the same bytes.
public enum JSON: Equatable, Sendable, Codable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    // ponytail: a Double, so an integer above 2^53 loses its low digits. Neither the API nor the tools carry one;
    // add an integer case if an identifier or counter that big ever does.
    case number(Double)
    case bool(Bool)
    case null

    /// The value in `data`, which may be any JSON value, not only an object or an array. Throws when `data` is not
    /// JSON.
    public static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    /// The value as UTF-8 JSON text with its keys sorted, so that equal values give equal bytes, which the prompt
    /// cache depends on; `pretty` adds line breaks and indentation. A whole number below 2^53 is written without a
    /// fraction (`12`, not `12.0`) and a number that is not finite as `null`, which is all JSON can say for it.
    public func encoded(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        // Cannot fail: `encode(to:)` writes every case, and writes no number that the encoder would refuse.
        return try! encoder.encode(self)
    }

    /// The member `key` of an object; `nil` for any other value, and for an object without that member.
    public subscript(key: String) -> JSON? { object?[key] }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    /// The number as an `Int` when it is a whole number that fits one, so `12.5` has none.
    public var int: Int? { if case .number(let value) = self { Int(exactly: value) } else { nil } }
    public var array: [JSON]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: JSON]? { if case .object(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // The decoder reads only `true` and `false` as a `Bool`, so a `1` or a `0` stays a number.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value):
            // The whole numbers are written as integers here, not left to Foundation, so that their bytes stay ours.
            if value.magnitude < Double(1 << 53), value == value.rounded() {
                try container.encode(Int(value))
            } else if value.isFinite {
                try container.encode(value)
            } else {
                try container.encodeNil()
            }
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
