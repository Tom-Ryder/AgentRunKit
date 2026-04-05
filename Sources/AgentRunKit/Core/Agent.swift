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
        approvalHandler: ToolApprovalHandler? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler
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
        approvalHandler: ToolApprovalHandler? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler
        )
        return stream(
            userMessage: userMessage, history: history,
            context: context, options: options
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
        if let tokenBudget = options.tokenBudget {
            precondition(tokenBudget >= 1, "tokenBudget must be at least 1")
        }
        precondition(
            configuration.approvalPolicy == .none || options.approvalHandler != nil,
            "approvalHandler is required when approvalPolicy is not .none"
        )
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
            let budgetUsage = try requireBudgetUsage(response.tokenUsage, budgetPhase: state.budgetPhase)

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
        approvalHandler: ToolApprovalHandler? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: nil,
            systemPromptOverride: systemPromptOverride, approvalHandler: approvalHandler
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
        if let tokenBudget = options.tokenBudget {
            precondition(tokenBudget >= 1, "tokenBudget must be at least 1")
        }
        precondition(
            configuration.approvalPolicy == .none || options.approvalHandler != nil,
            "approvalHandler is required when approvalPolicy is not .none"
        )
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
        var totalUsage = TokenUsage()
        var lastTotalTokens: Int?
        let policy = StreamPolicy.agent
        let processor = StreamProcessor(client: client, toolDefinitions: toolDefinitions, policy: policy)
        var compactor = ContextCompactor(client: client, toolDefinitions: toolDefinitions, configuration: configuration)
        state.budgetPhase = try makeBudgetPhase()

        for iterationNumber in 1 ... configuration.maxIterations {
            try Task.checkCancellation()

            try await compactStreamingMessagesIfNeeded(
                &state.messages,
                totalUsage: &totalUsage,
                lastTotalTokens: lastTotalTokens,
                compactor: &compactor,
                historyWasRewrittenLocally: &state.historyWasRewrittenLocally,
                continuation: continuation
            )
            let iteration = try await generateStreamingResponse(
                processor: processor,
                messages: &state.messages,
                totalUsage: &totalUsage,
                compactor: &compactor,
                historyWasRewrittenLocally: &state.historyWasRewrittenLocally,
                continuation: continuation,
                requestContext: options.requestContext
            )

            if let usage = iteration.usage {
                continuation.yield(.make(.iterationCompleted(usage: usage, iteration: iterationNumber)))
            }
            state.messages.append(.assistant(iteration.toAssistantMessage()))
            let budgetUsage = try requireBudgetUsage(iteration.usage, budgetPhase: state.budgetPhase)

            if try tryFinishOnTerminalEvent(
                iteration: iteration,
                totalUsage: totalUsage,
                history: state.messages,
                continuation: continuation
            ) {
                return
            }

            try await finalizeStreamingIteration(
                toolCalls: iteration.toolCalls,
                context: context,
                budgetUsage: budgetUsage,
                options: options,
                continuation: continuation,
                state: &state
            )

            if finishIfOverBudget(
                options.tokenBudget,
                totalUsage: totalUsage,
                history: state.messages,
                continuation: continuation
            ) {
                return
            }
            lastTotalTokens = iteration.usage?.total
        }

        finishStreaming(
            continuation: continuation,
            event: makeFinishedEvent(
                tokenUsage: totalUsage,
                content: nil,
                reason: .maxIterationsReached(limit: configuration.maxIterations),
                history: state.messages
            )
        )
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

    func parseFinishEvent(
        from finishCall: ToolCall,
        tokenUsage: TokenUsage,
        history: [ChatMessage]
    ) throws -> StreamEvent {
        let decoded: FinishArguments
        do {
            decoded = try JSONDecoder().decode(FinishArguments.self, from: finishCall.argumentsData)
        } catch {
            throw AgentError.finishDecodingFailed(message: String(describing: error))
        }
        return try makeFinishedEvent(
            tokenUsage: tokenUsage,
            content: decoded.content,
            reason: FinishReason(decoded.reason ?? "completed"),
            history: history.sanitizedTerminalHistory()
        )
    }

    func makeFinishedEvent(
        tokenUsage: TokenUsage,
        content: String?,
        reason: FinishReason?,
        history: [ChatMessage]
    ) -> StreamEvent {
        .make(.finished(
            tokenUsage: tokenUsage,
            content: content,
            reason: reason,
            history: history
        ))
    }

    func emitCompactionEventIfNeeded(
        _ compacted: Bool,
        lastTotalTokens: Int?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        guard compacted, let totalTokens = lastTotalTokens, let windowSize = client.contextWindowSize else {
            return
        }
        continuation.yield(.make(.compacted(totalTokens: totalTokens, windowSize: windowSize)))
    }

    func exclusiveFinishCall(in toolCalls: [ToolCall]) throws -> ToolCall? {
        let finishCalls = toolCalls.filter { $0.name == "finish" }
        guard !finishCalls.isEmpty else { return nil }
        guard finishCalls.count == 1, toolCalls.count == 1 else {
            throw AgentError.malformedHistory(.finishMustBeExclusive)
        }
        return finishCalls[0]
    }

    func indexedExecutableToolCalls(from toolCalls: [ToolCall]) -> [IndexedToolCall] {
        toolCalls.enumerated().compactMap { offset, call in
            guard StreamPolicy.agent.shouldExecuteTool(name: call.name) else { return nil }
            return IndexedToolCall(index: offset, call: call)
        }
    }

    private func finishIfOverBudget(
        _ tokenBudget: Int?,
        totalUsage: TokenUsage,
        history: [ChatMessage],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) -> Bool {
        guard let tokenBudget, totalUsage.total > tokenBudget else {
            return false
        }
        finishStreaming(
            continuation: continuation,
            event: makeFinishedEvent(
                tokenUsage: totalUsage,
                content: nil,
                reason: .tokenBudgetExceeded(budget: tokenBudget, used: totalUsage.total),
                history: history
            )
        )
        return true
    }

    func finishStreaming(
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        event: StreamEvent
    ) {
        continuation.yield(event)
        continuation.finish()
    }
}
