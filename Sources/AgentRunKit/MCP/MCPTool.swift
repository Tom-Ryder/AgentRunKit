import Foundation

/// Adapts an MCP-discovered tool to the ``AnyTool`` protocol.
public struct MCPTool<C: ToolContext>: AnyTool, Sendable {
    public typealias Context = C

    public let name: String
    public let description: String
    public let parametersSchema: JSONSchema
    private let client: MCPClient

    public init(info: MCPToolInfo, client: MCPClient) {
        name = info.name
        description = info.description
        parametersSchema = info.inputSchema
        self.client = client
    }

    public func execute(arguments: Data, context _: C) async throws -> ToolResult {
        do {
            return try await client.callTool(name: name, arguments: arguments).toToolResult()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentError {
            throw error
        } catch {
            throw AgentError.toolExecutionFailed(tool: name, message: String(describing: error))
        }
    }
}
