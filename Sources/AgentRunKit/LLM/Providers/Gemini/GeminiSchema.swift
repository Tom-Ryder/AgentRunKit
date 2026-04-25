import Foundation

struct GeminiSchema: Encodable {
    let wrapped: JSONSchema

    init(_ schema: JSONSchema) {
        wrapped = schema
    }

    private enum CodingKeys: String, CodingKey {
        case type, description, items, properties, required, anyOf
        case `enum`
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch wrapped {
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
            try container.encode(GeminiSchema(items), forKey: .items)
            try container.encodeIfPresent(description, forKey: .description)

        case let .object(properties, required, description):
            try container.encode("object", forKey: .type)
            try container.encode(
                properties.mapValues { GeminiSchema($0) },
                forKey: .properties
            )
            if !required.isEmpty {
                try container.encode(required, forKey: .required)
            }
            try container.encodeIfPresent(description, forKey: .description)
            // Intentionally omits additionalProperties: unsupported by Gemini API

        case .null:
            try container.encode("null", forKey: .type)

        case let .anyOf(schemas):
            try container.encode(schemas.map { GeminiSchema($0) }, forKey: .anyOf)
        }
    }
}
