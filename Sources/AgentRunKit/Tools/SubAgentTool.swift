import Foundation

public struct SubAgentTool<P: Codable & SchemaProviding & Sendable, InnerContext: ToolContext>: AnyTool {
    public typealias Context = SubAgentContext<InnerContext>

    public let name: String
    public let description: String
    public let parametersSchema: JSONSchema
    private let agent: Agent<SubAgentContext<InnerContext>>
    private let tokenBudget: Int?
    private let messageBuilder: @Sendable (P) -> String

    public init(
        name: String,
        description: String,
        agent: Agent<SubAgentContext<InnerContext>>,
        tokenBudget: Int? = nil,
        messageBuilder: @escaping @Sendable (P) -> String
    ) throws {
        try P.validateSchema()
        self.name = name
        self.description = description
        parametersSchema = P.jsonSchema
        self.agent = agent
        self.tokenBudget = tokenBudget
        self.messageBuilder = messageBuilder
    }

    public func execute(arguments: Data, context: SubAgentContext<InnerContext>) async throws -> ToolResult {
        let params: P
        do {
            params = try JSONDecoder().decode(P.self, from: arguments)
        } catch {
            throw AgentError.toolDecodingFailed(tool: name, message: String(describing: error))
        }
        guard context.currentDepth < context.maxDepth else {
            throw AgentError.maxDepthExceeded(depth: context.currentDepth)
        }
        let result = try await agent.run(
            userMessage: messageBuilder(params),
            context: context.descending(),
            tokenBudget: tokenBudget
        )
        return ToolResult(content: result.content)
    }
}

public func subAgentTool<P: Codable & SchemaProviding & Sendable, InnerContext: ToolContext>(
    name: String,
    description: String,
    agent: Agent<SubAgentContext<InnerContext>>,
    tokenBudget: Int? = nil,
    messageBuilder: @escaping @Sendable (P) -> String
) throws -> SubAgentTool<P, InnerContext> {
    try SubAgentTool(
        name: name,
        description: description,
        agent: agent,
        tokenBudget: tokenBudget,
        messageBuilder: messageBuilder
    )
}
