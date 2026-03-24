#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation
    import FoundationModels

    @available(macOS 26, iOS 26, *)
    struct FMToolAdapter<C: ToolContext>: FoundationModels.Tool, Sendable {
        let name: String
        let description: String
        let generationSchema: GenerationSchema

        typealias Arguments = GeneratedContent

        var parameters: GenerationSchema { generationSchema }

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
            let jsonValue = Self.toJSONValue(arguments)
            let data = try JSONEncoder().encode(jsonValue)
            let result = try await wrappedTool.execute(arguments: data, context: context)
            return result.content
        }

        static func toJSONValue(_ content: GeneratedContent) -> JSONValue {
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
                return .array(elements.map { toJSONValue($0) })
            case let .structure(properties, _):
                return .object(properties.mapValues { toJSONValue($0) })
            @unknown default:
                assertionFailure("Unhandled GeneratedContent.Kind: \(content.kind)")
                return .null
            }
        }
    }

#endif
