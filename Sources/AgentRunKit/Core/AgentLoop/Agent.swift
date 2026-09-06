import Foundation

/// The core agent runtime that executes the generate, tool-call, repeat loop.
///
/// For a guide, see <doc:AgentAndChat>.
public final class Agent<C: ToolContext>: Sendable {
    let client: any LLMClient
    let tools: [any AnyTool<C>]
    let toolDefinitions: [ToolDefinition]
    let configuration: AgentConfiguration
    let completionPolicy: AgentCompletionPolicy
    let completionTool: (any AnyTool<C>)?

    /// Creates an agent that finishes through the built-in finish tool.
    public convenience init(
        client: any LLMClient,
        tools: [any AnyTool<C>],
        configuration: AgentConfiguration = AgentConfiguration()
    ) {
        self.init(client: client, tools: tools, completing: nil, configuration: configuration)
    }

    /// Creates an agent that finishes by executing `completionTool` instead of the built-in finish tool.
    ///
    /// The completion tool must be the only call in its assistant message; state that requirement in its description.
    public convenience init(
        client: any ToolCallSurfacingClient,
        tools: [any AnyTool<C>],
        completionTool: any AnyTool<C>,
        configuration: AgentConfiguration = AgentConfiguration()
    ) {
        self.init(client: client, tools: tools, completing: completionTool, configuration: configuration)
    }

    private init(
        client: any LLMClient,
        tools: [any AnyTool<C>],
        completing completionTool: (any AnyTool<C>)?,
        configuration: AgentConfiguration
    ) {
        var executableTools = tools
        if let completionTool {
            executableTools.append(completionTool)
        }
        let reservedNames: Set = ["finish", "prune_context"]
        let names = executableTools.map(\.name)
        precondition(!names.contains(where: \.isEmpty), "Tool names must be non-empty")
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }.keys
        precondition(duplicates.isEmpty, "Duplicate tool names: \(duplicates.sorted().joined(separator: ", "))")
        let conflicts = names.filter { reservedNames.contains($0) }
        precondition(conflicts.isEmpty, "Reserved tool names: \(conflicts.sorted().joined(separator: ", "))")

        self.client = client
        self.tools = executableTools
        var defs = executableTools.map { ToolDefinition($0) }
        if completionTool == nil {
            defs.append(reservedFinishToolDefinition)
        }
        if configuration.contextBudget?.enablePruneTool == true {
            defs.append(reservedPruneContextToolDefinition)
        }
        toolDefinitions = defs
        self.configuration = configuration
        self.completionTool = completionTool
        completionPolicy = completionTool.map { .executableTool(name: $0.name) } ?? .builtInFinish
    }

    public func run(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AgentResult {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler
        )
        return try await run(
            userMessage: .user(userMessage), history: history,
            context: context, options: options
        )
    }

    public func run(
        userMessage: ChatMessage,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AgentResult {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler
        )
        return try await run(
            userMessage: userMessage, history: history,
            context: context, options: options
        )
    }

    public func stream(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil,
        sessionID: SessionID? = nil,
        checkpointer: (any AgentCheckpointer)? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler,
            sessionID: sessionID ?? SessionID(), runID: RunID(),
            checkpointer: checkpointer
        )
        return stream(
            userMessage: .user(userMessage), history: history,
            context: context, options: options
        )
    }

    public func stream(
        userMessage: ChatMessage,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil,
        sessionID: SessionID? = nil,
        checkpointer: (any AgentCheckpointer)? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler,
            sessionID: sessionID ?? SessionID(), runID: RunID(),
            checkpointer: checkpointer
        )
        return stream(
            userMessage: userMessage, history: history,
            context: context, options: options
        )
    }

    func validateInvocation(_ options: InvocationOptions) {
        if let tokenBudget = options.tokenBudget {
            precondition(tokenBudget >= 1, "tokenBudget must be at least 1")
        }
        precondition(
            configuration.approvalPolicy == .none || options.approvalHandler != nil,
            "approvalHandler is required when approvalPolicy is not .none"
        )
    }
}

struct AgentLoopState {
    var messages: [ChatMessage]
    var historyWasRewrittenLocally: Bool = false
    var budgetPhase: ContextBudgetPhase?
    var sessionAllowlist: Set<String> = []
}

func shouldTerminateOnContent(
    client: any LLMClient,
    toolCalls: [ToolCall],
    content: String
) -> Bool {
    client is any ContentOnlyTerminatingClient && toolCalls.isEmpty && !content.isEmpty
}

extension Agent {
    func run(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        systemPromptOverride: String?,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AgentResult {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: nil,
            systemPromptOverride: systemPromptOverride, approvalHandler: approvalHandler
        )
        return try await run(
            userMessage: .user(userMessage), history: history,
            context: context, options: options
        )
    }

    private func run(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        options: InvocationOptions
    ) async throws -> AgentResult {
        validateInvocation(options)
        var state = AgentLoopState(messages: initialMessages(
            systemPrompt: options.systemPromptOverride ?? configuration.systemPrompt,
            history: history, userMessage: userMessage
        ))
        try state.messages.validateForAgentHistory()

        var totalUsage = TokenUsage()
        var lastTotalTokens: Int?
        var compactor = ContextCompactor(client: client, configuration: configuration)
        state.budgetPhase = try makeBudgetPhase()

        for iteration in 1 ... configuration.maxIterations {
            try Task.checkCancellation()

            let response = try await executeRunIteration(
                messages: &state.messages,
                totalUsage: &totalUsage,
                lastTotalTokens: &lastTotalTokens,
                compactor: &compactor,
                historyWasRewrittenLocally: &state.historyWasRewrittenLocally,
                requestContext: options.requestContext
            )

            if let terminalResult = try await resolveRunIteration(
                response: response,
                context: context,
                iteration: iteration,
                totalUsage: totalUsage,
                options: options,
                state: &state
            ) {
                return terminalResult
            }
        }

        return makeTerminalResult(
            reason: .maxIterationsReached(limit: configuration.maxIterations),
            tokenUsage: totalUsage,
            iterations: configuration.maxIterations,
            history: state.messages
        )
    }

    func stream(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        systemPromptOverride: String?,
        approvalHandler: ToolApprovalHandler? = nil,
        sessionID: SessionID? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: nil,
            systemPromptOverride: systemPromptOverride, approvalHandler: approvalHandler,
            sessionID: sessionID ?? SessionID(), runID: RunID()
        )
        return stream(
            userMessage: .user(userMessage), history: history,
            context: context, options: options
        )
    }
}

extension Agent {
    func stream(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        options: InvocationOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        validateInvocation(options)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        userMessage: userMessage,
                        history: history,
                        context: context,
                        options: options,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func performStream(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var state = AgentLoopState(messages: initialMessages(
            systemPrompt: options.systemPromptOverride ?? configuration.systemPrompt,
            history: history, userMessage: userMessage
        ))
        try state.messages.validateForAgentHistory()
        state.budgetPhase = try makeBudgetPhase()
        try await performStreamLoop(
            state: &state, startIteration: 1,
            totalUsage: TokenUsage(), lastTotalTokens: nil,
            context: context, options: options,
            continuation: continuation
        )
    }

    func performStreamLoop(
        state: inout AgentLoopState,
        startIteration: Int,
        totalUsage: TokenUsage,
        lastTotalTokens: Int?,
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var totalUsage = totalUsage
        var lastTotalTokens = lastTotalTokens
        let processor = StreamProcessor(
            client: client, toolDefinitions: toolDefinitions, policy: .agent(completionPolicy),
            eventFactory: options.eventFactory
        )
        var compactor = ContextCompactor(client: client, configuration: configuration)

        let iterationContext = StreamIterationContext(
            processor: processor, context: context, options: options, continuation: continuation
        )
        guard startIteration <= configuration.maxIterations else {
            finishStreaming(
                continuation: continuation,
                event: makeFinishedEvent(
                    tokenUsage: totalUsage, content: nil,
                    reason: .maxIterationsReached(limit: configuration.maxIterations),
                    history: state.messages, eventFactory: options.eventFactory
                )
            )
            return
        }
        for iterationNumber in startIteration ... configuration.maxIterations {
            try Task.checkCancellation()
            let isFinished = try await runStreamIteration(
                iterationNumber: iterationNumber,
                state: &state, totalUsage: &totalUsage,
                lastTotalTokens: &lastTotalTokens,
                compactor: &compactor,
                iterationContext: iterationContext
            )
            if isFinished { return }
        }

        finishStreaming(
            continuation: continuation,
            event: makeFinishedEvent(
                tokenUsage: totalUsage, content: nil,
                reason: .maxIterationsReached(limit: configuration.maxIterations),
                history: state.messages, eventFactory: options.eventFactory
            )
        )
    }

    struct StreamIterationContext {
        let processor: StreamProcessor
        let context: C
        let options: InvocationOptions
        let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    }

    private func runStreamIteration(
        iterationNumber: Int,
        state: inout AgentLoopState,
        totalUsage: inout TokenUsage,
        lastTotalTokens: inout Int?,
        compactor: inout ContextCompactor,
        iterationContext: StreamIterationContext
    ) async throws -> Bool {
        let factory = iterationContext.options.eventFactory
        let continuation = iterationContext.continuation
        try await compactStreamingMessagesIfNeeded(
            &state.messages,
            totalUsage: &totalUsage,
            lastTotalTokens: lastTotalTokens,
            compactor: &compactor,
            historyWasRewrittenLocally: &state.historyWasRewrittenLocally,
            eventFactory: factory,
            continuation: continuation
        )
        let iteration = try await generateStreamingResponse(
            processor: iterationContext.processor,
            messages: &state.messages,
            totalUsage: &totalUsage,
            compactor: &compactor,
            historyWasRewrittenLocally: &state.historyWasRewrittenLocally,
            continuation: continuation,
            options: iterationContext.options
        )
        state.messages.append(.assistant(iteration.toAssistantMessage()))
        yieldIterationCompleted(
            iteration: iteration, iterationNumber: iterationNumber,
            messages: state.messages, context: iterationContext.context,
            eventFactory: factory, continuation: continuation
        )
        if try await resolveStreamingIteration(
            iteration: iteration, iterationNumber: iterationNumber, totalUsage: totalUsage,
            iterationContext: iterationContext, state: &state
        ) {
            return true
        }
        try await checkpointIfConfigured(
            iterationNumber: iterationNumber, state: state,
            totalUsage: totalUsage, iterationUsage: iteration.usage,
            eventFactory: factory, checkpointer: iterationContext.options.checkpointer
        )
        if finishIfOverBudget(
            iterationContext.options.tokenBudget, totalUsage: totalUsage,
            history: state.messages, eventFactory: factory, continuation: continuation
        ) {
            return true
        }
        lastTotalTokens = iteration.usage?.total
        return false
    }

    func indexedToolCalls(from toolCalls: [ToolCall]) -> [IndexedToolCall] {
        toolCalls.enumerated().map { offset, call in IndexedToolCall(index: offset, call: call) }
    }
}
