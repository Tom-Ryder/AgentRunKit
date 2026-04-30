import Foundation

enum ProviderExtraFields {
    static func validateAllowedKeys(
        _ fields: [String: JSONValue],
        allowedKeys: Set<String>,
        debugDescriptionPrefix: String,
        codingPath: [any CodingKey]
    ) throws {
        let invalidKeys = fields.keys.filter { !allowedKeys.contains($0) }
        try reject(
            invalidKeys,
            fields: fields,
            debugDescriptionPrefix: debugDescriptionPrefix,
            codingPath: codingPath
        )
    }

    static func rejectReservedKeys(
        _ fields: [String: JSONValue],
        reservedKeys: Set<String>,
        debugDescriptionPrefix: String,
        codingPath: [any CodingKey]
    ) throws {
        let invalidKeys = fields.keys.filter { reservedKeys.contains($0) }
        try reject(
            invalidKeys,
            fields: fields,
            debugDescriptionPrefix: debugDescriptionPrefix,
            codingPath: codingPath
        )
    }

    static func encode(_ fields: [String: JSONValue], to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in fields {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }

    private static func reject(
        _ keys: [String],
        fields: [String: JSONValue],
        debugDescriptionPrefix: String,
        codingPath: [any CodingKey]
    ) throws {
        guard !keys.isEmpty else { return }
        throw EncodingError.invalidValue(
            fields,
            EncodingError.Context(
                codingPath: codingPath,
                debugDescription: debugDescriptionPrefix + keys.sorted().joined(separator: ", ")
            )
        )
    }
}
