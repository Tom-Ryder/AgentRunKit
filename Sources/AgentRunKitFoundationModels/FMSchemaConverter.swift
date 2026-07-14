#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation
    import FoundationModels

    @available(macOS 26, iOS 26, *)
    enum FMSchemaConverter {
        private static let rootName = "Arguments"

        static func convert(_ schema: JSONSchema) throws -> GenerationSchema {
            guard case let .object(properties, required, description) = schema else {
                throw AgentError.schemaInferenceFailed(
                    type: rootName,
                    message: "Top-level schema must be an object"
                )
            }
            var compilation = Compilation()
            let root = try compilation.compileObject(
                named: rootName,
                properties: properties,
                required: required,
                description: description
            )
            return try GenerationSchema(root: root, dependencies: compilation.dependencies)
        }

        private struct Compilation {
            private(set) var dependencies: [DynamicGenerationSchema] = []
            private var nextObjectOrdinal = 1

            mutating func compileObject(
                named name: String,
                properties: [String: JSONSchema],
                required: [String],
                description: String?
            ) throws -> DynamicGenerationSchema {
                if let unknown = required.first(where: { properties[$0] == nil }) {
                    throw AgentError.schemaInferenceFailed(
                        type: name,
                        message: "required key '\(unknown)' has no matching property"
                    )
                }
                var compiledProperties: [DynamicGenerationSchema.Property] = []
                for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
                    try compiledProperties.append(DynamicGenerationSchema.Property(
                        name: key,
                        description: descriptionFor(value),
                        schema: compileProperty(value),
                        isOptional: !required.contains(key)
                    ))
                }
                return DynamicGenerationSchema(name: name, description: description, properties: compiledProperties)
            }

            private mutating func compileProperty(_ schema: JSONSchema) throws -> DynamicGenerationSchema {
                switch schema {
                case let .string(_, enumValues):
                    if enumValues != nil {
                        throw AgentError.schemaInferenceFailed(
                            type: "string",
                            message: "enum values are not supported by the Foundation Models schema converter"
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
                    return try DynamicGenerationSchema(arrayOf: compileProperty(items))
                case let .object(properties, required, description):
                    let name = "Object_\(nextObjectOrdinal)"
                    nextObjectOrdinal += 1
                    let definition = try compileObject(
                        named: name,
                        properties: properties,
                        required: required,
                        description: description
                    )
                    dependencies.append(definition)
                    return DynamicGenerationSchema(referenceTo: name)
                case let .anyOf(schemas):
                    let nonNull = schemas.filter { $0 != .null }
                    guard nonNull.count == 1, let inner = nonNull.first else {
                        throw AgentError.schemaInferenceFailed(
                            type: "anyOf",
                            message: "This converter supports anyOf only as a single non-null type paired with null"
                        )
                    }
                    return try compileProperty(inner)
                case .null:
                    throw AgentError.schemaInferenceFailed(
                        type: "null",
                        message: "Standalone null is not supported by the Foundation Models schema converter"
                    )
                }
            }

            private func descriptionFor(_ schema: JSONSchema) -> String? {
                switch schema {
                case let .string(description, _): description
                case let .integer(description): description
                case let .number(description): description
                case let .boolean(description): description
                case let .array(_, description): description
                case let .object(_, _, description): description
                case let .anyOf(schemas): schemas.first { $0 != .null }.flatMap(descriptionFor)
                case .null: nil
                }
            }
        }
    }

#endif
