import Foundation

public struct Tool<P: Codable & SchemaProviding & Sendable, O: Codable & Sendable, C: ToolContext>: AnyTool {
    public typealias Context = C

    public let name: String
    public let description: String
    private let executor: @Sendable (P, C) async throws -> O

    public var parametersSchema: JSONSchema { P.jsonSchema }

    public init(
        name: String,
        description: String,
        executor: @escaping @Sendable (P, C) async throws -> O
    ) {
        self.name = name
        self.description = description
        self.executor = executor
    }

    public func execute(arguments: Data, context: C) async throws -> ToolResult {
        let params: P
        do {
            params = try JSONDecoder().decode(P.self, from: arguments)
        } catch {
            throw AgentError.toolDecodingFailed(tool: name, message: String(describing: error))
        }
        let output: O
        do {
            output = try await executor(params, context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentError.toolExecutionFailed(tool: name, message: String(describing: error))
        }
        let outputData: Data
        do {
            outputData = try JSONEncoder().encode(output)
        } catch {
            throw AgentError.toolEncodingFailed(tool: name, message: String(describing: error))
        }
        guard let content = String(data: outputData, encoding: .utf8) else {
            throw AgentError.toolEncodingFailed(tool: name, message: "JSONEncoder produced non-UTF8 output")
        }
        return ToolResult(content: content)
    }
}
