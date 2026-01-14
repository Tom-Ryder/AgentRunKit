import Foundation

public indirect enum JSONSchema: Sendable, Equatable {
    case string(description: String? = nil)
    case integer(description: String? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)
    case array(items: JSONSchema, description: String? = nil)
    case object(properties: [String: JSONSchema], required: [String], description: String? = nil)
    case null
    case anyOf([JSONSchema])
}

public extension JSONSchema {
    func optional() -> JSONSchema {
        .anyOf([self, .null])
    }
}

extension JSONSchema: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .string(description):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

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
    }
}
