#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation
    import FoundationModels

    @available(macOS 26, iOS 26, *)
    enum FMSchemaConverter {
        static func convert(_ schema: JSONSchema) throws -> GenerationSchema {
            let root = try convertToSchema(schema, name: "Arguments")
            return try GenerationSchema(root: root, dependencies: [])
        }

        private static func convertToSchema(
            _ schema: JSONSchema,
            name: String
        ) throws -> DynamicGenerationSchema {
            switch schema {
            case let .object(properties, required, description):
                let fmProperties = try properties.sorted(by: { $0.key < $1.key }).map { key, value in
                    let isOptional = !required.contains(key)
                    let propSchema = try convertPropertySchema(value)
                    return DynamicGenerationSchema.Property(
                        name: key,
                        description: descriptionFor(value),
                        schema: propSchema,
                        isOptional: isOptional
                    )
                }
                return DynamicGenerationSchema(
                    name: name,
                    description: description,
                    properties: fmProperties
                )

            default:
                throw AgentError.schemaInferenceFailed(
                    type: name,
                    message: "Top-level schema must be an object"
                )
            }
        }

        private static func convertPropertySchema(
            _ schema: JSONSchema
        ) throws -> DynamicGenerationSchema {
            switch schema {
            case let .string(_, enumValues):
                if enumValues != nil {
                    throw AgentError.schemaInferenceFailed(
                        type: "string",
                        message: "enumValues not supported by DynamicGenerationSchema"
                    )
                }
                return DynamicGenerationSchema(type: String.self)
            case .integer:
                return DynamicGenerationSchema(type: Int.self)
            case .number:
                return DynamicGenerationSchema(type: Double.self)
            case .boolean:
                return DynamicGenerationSchema(type: Bool.self)
            case let .array(items, _):
                let itemSchema = try convertPropertySchema(items)
                return DynamicGenerationSchema(arrayOf: itemSchema)
            case let .object(properties, required, description):
                let fmProperties = try properties.sorted(by: { $0.key < $1.key }).map { key, value in
                    let isOptional = !required.contains(key)
                    let propSchema = try convertPropertySchema(value)
                    return DynamicGenerationSchema.Property(
                        name: key,
                        description: descriptionFor(value),
                        schema: propSchema,
                        isOptional: isOptional
                    )
                }
                return DynamicGenerationSchema(
                    name: "Nested",
                    description: description,
                    properties: fmProperties
                )
            case let .anyOf(schemas):
                let nonNull = schemas.filter { $0 != .null }
                guard nonNull.count == 1, let inner = nonNull.first else {
                    throw AgentError.schemaInferenceFailed(
                        type: "anyOf",
                        message: "Only anyOf with a single non-null type is supported"
                    )
                }
                return try convertPropertySchema(inner)
            case .null:
                throw AgentError.schemaInferenceFailed(
                    type: "null",
                    message: "Standalone null type not supported by Foundation Models"
                )
            }
        }

        private static func descriptionFor(_ schema: JSONSchema) -> String? {
            switch schema {
            case let .string(description, _): description
            case let .integer(description): description
            case let .number(description): description
            case let .boolean(description): description
            case let .array(_, description): description
            case let .object(_, _, description): description
            case .null, .anyOf: nil
            }
        }
    }

#endif
