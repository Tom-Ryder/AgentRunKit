import Foundation

/// A wire-format tool description sent to LLM providers.
public struct ToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersSchema: JSONSchema
    public let strict: Bool?

    public init(
        name: String,
        description: String,
        parametersSchema: JSONSchema,
        strict: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.strict = strict
    }

    public init(_ tool: some AnyTool) {
        name = tool.name
        description = tool.description
        parametersSchema = tool.parametersSchema
        strict = tool.strict
    }
}
