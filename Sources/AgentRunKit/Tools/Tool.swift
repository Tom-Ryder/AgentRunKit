import Foundation

/// A typed tool with compile-time schema validation.
///
/// For guidance on defining tools, see <doc:DefiningTools>.
public struct Tool<P: Codable & SchemaProviding & Sendable, O: Codable & Sendable, C: ToolContext>: AnyTool {
    public typealias Context = C

    public let name: String
    public let description: String
    public let parametersSchema: JSONSchema
    public let isConcurrencySafe: Bool
    public let isReadOnly: Bool
    public let maxResultCharacters: Int?
    public let strict: Bool?
    public let toolTimeout: Duration?
    private let executor: @Sendable (P, C) async throws -> O

    public init(
        name: String,
        description: String,
        isConcurrencySafe: Bool = false,
        isReadOnly: Bool = false,
        maxResultCharacters: Int? = nil,
        strict: Bool? = nil,
        toolTimeout: Duration? = nil,
        executor: @escaping @Sendable (P, C) async throws -> O
    ) throws {
        if let maxResultCharacters {
            precondition(maxResultCharacters >= 1, "maxResultCharacters must be at least 1")
        }
        if let toolTimeout {
            precondition(toolTimeout >= .milliseconds(1), "toolTimeout must be at least 1ms")
        }
        try P.validateSchema()
        self.name = name
        self.description = description
        self.isConcurrencySafe = isConcurrencySafe
        self.isReadOnly = isReadOnly
        self.maxResultCharacters = maxResultCharacters
        self.strict = strict
        self.toolTimeout = toolTimeout
        parametersSchema = P.jsonSchema
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
        } catch let error as AgentError {
            throw error
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
