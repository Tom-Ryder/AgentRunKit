import Foundation

/// Specifies a JSON schema constraint on the model's response.
///
/// For usage details, see <doc:StructuredOutput>.
public struct ResponseFormat: Sendable, Encodable {
    private let type: String
    private let jsonSchema: ResponseJSONSchema

    private init(name: String, schema: JSONSchema) {
        type = "json_schema"
        jsonSchema = ResponseJSONSchema(name: name, strict: true, schema: schema)
    }

    public static func jsonSchema<T: SchemaProviding>(_: T.Type) -> ResponseFormat {
        ResponseFormat(name: sanitizeTypeName(String(describing: T.self)), schema: T.jsonSchema)
    }

    private static func sanitizeTypeName(_ name: String) -> String {
        name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
            .map(String.init)
            .joined()
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

private struct ResponseJSONSchema: Encodable {
    let name: String
    let strict: Bool
    let schema: JSONSchema
}

extension ResponseFormat {
    var schemaName: String {
        jsonSchema.name
    }
}

package extension ResponseFormat {
    var schema: JSONSchema {
        jsonSchema.schema
    }
}
