import Foundation

public struct ToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersSchema: JSONSchema

    public init(name: String, description: String, parametersSchema: JSONSchema) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
    }

    public init(_ tool: some AnyTool) {
        name = tool.name
        description = tool.description
        parametersSchema = tool.parametersSchema
    }
}
