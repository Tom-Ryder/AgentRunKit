#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation
    import FoundationModels

    @available(macOS 26, iOS 26, *)
    struct FMToolAdapter<C: ToolContext>: FoundationModels.Tool {
        let name: String
        let description: String
        let generationSchema: GenerationSchema

        typealias Arguments = GeneratedContent

        var parameters: GenerationSchema {
            generationSchema
        }

        private let wrappedTool: any AnyTool<C>
        private let context: C

        init(wrapping tool: any AnyTool<C>, context: C) throws {
            name = tool.name
            description = tool.description
            wrappedTool = tool
            self.context = context
            generationSchema = try FMSchemaConverter.convert(tool.parametersSchema)
        }

        func call(arguments: GeneratedContent) async throws -> String {
            let jsonValue = try Self.toJSONValue(arguments)
            let data = try JSONEncoder().encode(jsonValue)
            let result = try await wrappedTool.execute(arguments: data, context: context)
            return result.content
        }

        static func toJSONValue(_ content: GeneratedContent) throws -> JSONValue {
            switch content.kind {
            case .null:
                return .null
            case let .bool(value):
                return .bool(value)
            case let .number(value):
                if let intValue = Int(exactly: value) {
                    return .int(intValue)
                }
                return .double(value)
            case let .string(value):
                return .string(value)
            case let .array(elements):
                return try .array(elements.map { try toJSONValue($0) })
            case let .structure(properties, _):
                return try .object(properties.mapValues { try toJSONValue($0) })
            @unknown default:
                throw AgentError.llmError(
                    .decodingFailed(description: "Unsupported FoundationModels GeneratedContent.Kind: \(content.kind)")
                )
            }
        }
    }

#endif
