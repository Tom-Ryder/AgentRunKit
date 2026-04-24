import Foundation

/// The core agent runtime that executes the generate, tool-call, repeat loop.
///
/// For a guide, see <doc:AgentAndChat>.
public final class Agent<C: ToolContext>: Sendable {
    let client: any LLMClient
    let tools: [any AnyTool<C>]
    let toolDefinitions: [ToolDefinition]
    let configuration: AgentConfiguration

    public init(
        client: any LLMClient,
        tools: [any AnyTool<C>],
        configuration: AgentConfiguration = AgentConfiguration()
    ) {
        let reservedNames: Set = ["finish", "prune_context"]
        let names = tools.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }.keys
        precondition(duplicates.isEmpty, "Duplicate tool names: \(duplicates.sorted().joined(separator: ", "))")
        let conflicts = names.filter { reservedNames.contains($0) }
        precondition(conflicts.isEmpty, "Reserved tool names: \(conflicts.sorted().joined(separator: ", "))")

        self.client = client
        self.tools = tools
        var defs = tools.map { ToolDefinition($0) } + [reservedFinishToolDefinition]
        if configuration.contextBudget?.enablePruneTool == true {
            defs.append(reservedPruneContextToolDefinition)
        }
        toolDefinitions = defs
        self.configuration = configuration
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

struct RunLoopState {
    var messages: [ChatMessage]
    var historyWasRewrittenLocally: Bool = false
    var budgetPhase: ContextBudgetPhase?
    var sessionAllowlist: Set<String> = []
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
        var state = RunLoopState(messages: buildInitialMessages(
            userMessage: userMessage, history: history,
            systemPromptOverride: options.systemPromptOverride
        ))
        try state.messages.validateForAgentHistory()

        var totalUsage = TokenUsage()
        var lastTotalTokens: Int?
        var compactor = ContextCompactor(
            client: client, toolDefinitions: toolDefinitions, configuration: configuration
        )
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
            let budgetUsage = response.tokenUsage

            if let finishCall = try exclusiveFinishCall(in: response.toolCalls) {
                return try parseFinishResult(
                    finishCall,
                    tokenUsage: totalUsage,
                    iterations: iteration,
                    history: state.messages
                )
            }

            if client is any ContentOnlyTerminatingClient,
               response.toolCalls.isEmpty,
               !response.content.isEmpty {
                return try AgentResult(
                    finishReason: .completed,
                    content: response.content,
                    totalTokenUsage: totalUsage,
                    iterations: iteration,
                    history: state.messages.sanitizedTerminalHistory()
                )
            }

            if let terminalResult = try await finalizeRunIteration(
                toolCalls: response.toolCalls,
                context: context,
                iteration: iteration,
                totalUsage: totalUsage,
                budgetUsage: budgetUsage,
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

    func finalizeRunIteration(
        toolCalls: [ToolCall],
        context: C,
        iteration: Int,
        totalUsage: TokenUsage,
        budgetUsage: TokenUsage?,
        options: InvocationOptions,
        state: inout RunLoopState
    ) async throws -> AgentResult? {
        let indexedCalls = indexedExecutableToolCalls(from: toolCalls)
        let pruneCalls = indexedCalls.filter { $0.call.name == "prune_context" }
        let regularCalls = indexedCalls.filter { $0.call.name != "prune_context" }

        let pruneOutcome = executePruneCalls(pruneCalls, messages: &state.messages)
        if pruneOutcome.historyWasRewritten {
            state.historyWasRewrittenLocally = true
        }
        let regularResults = try await executeResults(
            regularCalls,
            context: context,
            messages: state.messages,
            approvalHandler: options.approvalHandler,
            allowlist: &state.sessionAllowlist
        )
        appendToolResults(
            (pruneOutcome.results + regularResults).sorted { $0.index < $1.index },
            messages: &state.messages
        )
        if let budgetUsage {
            applyBudgetPhase(&state.budgetPhase, usage: budgetUsage, messages: &state.messages)
        }
        try state.messages.validateForAgentHistory()

        if let tokenBudget = options.tokenBudget, totalUsage.total > tokenBudget {
            return makeTerminalResult(
                reason: .tokenBudgetExceeded(budget: tokenBudget, used: totalUsage.total),
                tokenUsage: totalUsage,
                iterations: iteration,
                history: state.messages
            )
        }
        return nil
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
        var state = StreamingLoopState(messages: buildInitialMessages(
            userMessage: userMessage, history: history, systemPromptOverride: options.systemPromptOverride
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
        state: inout StreamingLoopState,
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
            client: client, toolDefinitions: toolDefinitions, policy: .agent,
            eventFactory: options.eventFactory
        )
        var compactor = ContextCompactor(client: client, toolDefinitions: toolDefinitions, configuration: configuration)

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
        state: inout StreamingLoopState,
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
            requestContext: iterationContext.options.requestContext
        )
        state.messages.append(.assistant(iteration.toAssistantMessage()))
        yieldIterationCompletedIfPossible(
            iteration: iteration, iterationNumber: iterationNumber,
            messages: state.messages, context: iterationContext.context,
            eventFactory: factory, continuation: continuation
        )
        if try tryFinishOnTerminalEvent(
            iteration: iteration, totalUsage: totalUsage,
            history: state.messages, eventFactory: factory, continuation: continuation
        ) {
            return true
        }
        try await finalizeStreamingIteration(
            toolCalls: iteration.toolCalls, context: iterationContext.context,
            budgetUsage: iteration.usage, options: iterationContext.options,
            continuation: continuation, state: &state
        )
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

    func buildInitialMessages(
        userMessage: ChatMessage,
        history: [ChatMessage],
        systemPromptOverride: String? = nil
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let systemPrompt = systemPromptOverride ?? configuration.systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(contentsOf: history)
        messages.append(userMessage)
        return messages
    }

    func indexedExecutableToolCalls(from toolCalls: [ToolCall]) -> [IndexedToolCall] {
        toolCalls.enumerated().compactMap { offset, call in
            guard StreamPolicy.agent.shouldExecuteTool(name: call.name) else { return nil }
            return IndexedToolCall(index: offset, call: call)
        }
    }
}
