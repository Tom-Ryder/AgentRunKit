import Foundation

/// A JSON Schema representation for tool parameter validation.
///
/// For guidance on defining tools, see <doc:DefiningTools>.
public indirect enum JSONSchema: Sendable, Equatable {
    case string(description: String? = nil, enumValues: [String]? = nil)
    case integer(description: String? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)
    case array(items: JSONSchema, description: String? = nil)
    case object(properties: [String: JSONSchema], required: [String], description: String? = nil)
    case null
    case anyOf([JSONSchema])
}

public extension JSONSchema {
    /// Wraps this schema in an `anyOf` with `null` to represent an optional value.
    func optional() -> JSONSchema {
        .anyOf([self, .null])
    }
}

extension JSONSchema: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .string(description, enumValues):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(enumValues, forKey: .enum)

        case let .integer(description):
            try container.encode("integer", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .number(description):
            try container.encode("number", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .boolean(description):
            try container.encode("boolean", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .array(items, description):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
            try container.encodeIfPresent(description, forKey: .description)

        case let .object(properties, required, description):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            if !required.isEmpty {
                try container.encode(required, forKey: .required)
            }
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(false, forKey: .additionalProperties)

        case .null:
            try container.encode("null", forKey: .type)

        case let .anyOf(schemas):
            try container.encode(schemas, forKey: .anyOf)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, description, items, properties, required, anyOf, additionalProperties
        case `enum`
    }
}

extension JSONSchema: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let schemas = try container.decodeIfPresent([JSONSchema].self, forKey: .anyOf) {
            self = .anyOf(schemas)
            return
        }

        guard let type = try container.decodeIfPresent(String.self, forKey: .type) else {
            self = .object(properties: [:], required: [])
            return
        }

        let description = try container.decodeIfPresent(String.self, forKey: .description)

        switch type {
        case "string":
            let enumValues = try container.decodeIfPresent([String].self, forKey: .enum)
            self = .string(description: description, enumValues: enumValues)
        case "integer":
            self = .integer(description: description)
        case "number":
            self = .number(description: description)
        case "boolean":
            self = .boolean(description: description)
        case "null":
            self = .null
        case "array":
            let items = try container.decode(JSONSchema.self, forKey: .items)
            self = .array(items: items, description: description)
        case "object":
            let properties = try container.decodeIfPresent([String: JSONSchema].self, forKey: .properties) ?? [:]
            let required = try container.decodeIfPresent([String].self, forKey: .required) ?? []
            self = .object(properties: properties, required: required, description: description)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown JSON Schema type: '\(type)'"
            )
        }
    }
}
