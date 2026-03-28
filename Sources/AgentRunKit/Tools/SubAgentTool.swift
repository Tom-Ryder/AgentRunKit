import Foundation

/// Wraps an Agent as a callable tool with depth control and token budgets.
///
/// For guidance on composing sub-agents, see <doc:SubAgents>.
public struct SubAgentTool<P: Codable & SchemaProviding & Sendable, InnerContext: ToolContext>: AnyTool,
    StreamableSubAgentTool, TimeoutOverriding {
    public typealias Context = SubAgentContext<InnerContext>

    public let name: String
    public let description: String
    public let parametersSchema: JSONSchema
    let toolTimeout: Duration?
    private let agent: Agent<SubAgentContext<InnerContext>>
    private let tokenBudget: Int?
    private let inheritParentMessages: Bool
    private let messageBuilder: @Sendable (P) -> String
    private let systemPromptBuilder: (@Sendable (P) -> String)?

    public init(
        name: String,
        description: String,
        agent: Agent<SubAgentContext<InnerContext>>,
        tokenBudget: Int? = nil,
        toolTimeout: Duration? = nil,
        inheritParentMessages: Bool = false,
        systemPromptBuilder: (@Sendable (P) -> String)? = nil,
        messageBuilder: @escaping @Sendable (P) -> String
    ) throws {
        try P.validateSchema()
        self.name = name
        self.description = description
        parametersSchema = P.jsonSchema
        self.agent = agent
        self.tokenBudget = tokenBudget
        self.toolTimeout = toolTimeout
        self.inheritParentMessages = inheritParentMessages
        self.systemPromptBuilder = systemPromptBuilder
        self.messageBuilder = messageBuilder
    }

    public func execute(arguments: Data, context: SubAgentContext<InnerContext>) async throws -> ToolResult {
        let params = try decodeParams(arguments)
        guard context.currentDepth < context.maxDepth else {
            throw AgentError.maxDepthExceeded(depth: context.currentDepth)
        }
        let history = inheritParentMessages ? context.parentHistory.filter { !$0.isSystem } : []
        let result = try await agent.run(
            userMessage: messageBuilder(params),
            history: history,
            context: context.descending(),
            tokenBudget: tokenBudget,
            systemPromptOverride: systemPromptBuilder?(params)
        )
        return ToolResult(content: result.content, isError: result.finishReason == .error)
    }

    func executeStreaming(
        toolCallId _: String,
        arguments: Data,
        context: SubAgentContext<InnerContext>,
        eventHandler: @Sendable (StreamEvent) -> Void
    ) async throws -> ToolResult {
        let params = try decodeParams(arguments)
        guard context.currentDepth < context.maxDepth else {
            throw AgentError.maxDepthExceeded(depth: context.currentDepth)
        }
        let history = inheritParentMessages ? context.parentHistory.filter { !$0.isSystem } : []
        let stream = agent.stream(
            userMessage: messageBuilder(params),
            history: history,
            context: context.descending(),
            tokenBudget: tokenBudget,
            systemPromptOverride: systemPromptBuilder?(params)
        )

        var finalContent: String?
        var finalReason: FinishReason?
        for try await event in stream {
            eventHandler(event)
            if case let .finished(_, content, reason, _) = event {
                finalContent = content
                finalReason = reason
            }
        }

        guard let content = finalContent else {
            return ToolResult.error("Sub-agent stream ended without finishing")
        }
        return ToolResult(content: content, isError: finalReason == .error)
    }

    private func decodeParams(_ arguments: Data) throws -> P {
        do {
            return try JSONDecoder().decode(P.self, from: arguments)
        } catch {
            throw AgentError.toolDecodingFailed(tool: name, message: String(describing: error))
        }
    }
}

/// Creates a SubAgentTool with improved type inference at the call site.
public func subAgentTool<P: Codable & SchemaProviding & Sendable, InnerContext: ToolContext>(
    name: String,
    description: String,
    agent: Agent<SubAgentContext<InnerContext>>,
    tokenBudget: Int? = nil,
    toolTimeout: Duration? = nil,
    inheritParentMessages: Bool = false,
    systemPromptBuilder: (@Sendable (P) -> String)? = nil,
    messageBuilder: @escaping @Sendable (P) -> String
) throws -> SubAgentTool<P, InnerContext> {
    try SubAgentTool(
        name: name,
        description: description,
        agent: agent,
        tokenBudget: tokenBudget,
        toolTimeout: toolTimeout,
        inheritParentMessages: inheritParentMessages,
        systemPromptBuilder: systemPromptBuilder,
        messageBuilder: messageBuilder
    )
}
