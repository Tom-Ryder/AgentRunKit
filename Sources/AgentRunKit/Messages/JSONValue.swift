import Foundation

/// A type-safe representation of arbitrary JSON values.
public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(str): try container.encode(str)
        case let .int(num): try container.encode(num)
        case let .double(num): try container.encode(num)
        case let .bool(flag): try container.encode(flag)
        case .null: try container.encodeNil()
        case let .array(arr): try container.encode(arr)
        case let .object(obj): try container.encode(obj)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }

    static func fromJSONObject(_ value: Any) throws -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if let intValue = Int(exactly: number) {
                return .int(intValue)
            }
            return .double(number.doubleValue)
        case let array as [Any]:
            return try .array(array.map { try fromJSONObject($0) })
        case let dict as [String: Any]:
            return try .object(dict.mapValues { try fromJSONObject($0) })
        case is NSNull:
            return .null
        default:
            throw AgentError.llmError(.decodingFailed(description: "Unsupported JSON type: \(type(of: value))"))
        }
    }
}
