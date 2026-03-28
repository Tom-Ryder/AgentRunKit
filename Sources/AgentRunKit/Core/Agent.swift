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
        requestContext: RequestContext? = nil
    ) async throws -> AgentResult {
        try await run(
            userMessage: .user(userMessage), history: history, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext, systemPromptOverride: nil
        )
    }

    public func run(
        userMessage: ChatMessage,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil
    ) async throws -> AgentResult {
        try await run(
            userMessage: userMessage, history: history, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext, systemPromptOverride: nil
        )
    }

    public func stream(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            userMessage: .user(userMessage),
            history: history,
            context: context,
            tokenBudget: tokenBudget,
            requestContext: requestContext
        )
    }

    public func stream(
        userMessage: ChatMessage,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            userMessage: userMessage, history: history, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext, systemPromptOverride: nil
        )
    }
}

extension Agent {
    func run(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        systemPromptOverride: String?
    ) async throws -> AgentResult {
        try await run(
            userMessage: .user(userMessage), history: history, context: context,
            tokenBudget: tokenBudget, requestContext: nil, systemPromptOverride: systemPromptOverride
        )
    }

    private func run(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        tokenBudget: Int?,
        requestContext: RequestContext?,
        systemPromptOverride: String?
    ) async throws -> AgentResult {
        if let tokenBudget { precondition(tokenBudget >= 1, "tokenBudget must be at least 1") }
        var messages = buildInitialMessages(
            userMessage: userMessage, history: history, systemPromptOverride: systemPromptOverride
        )

        var totalUsage = TokenUsage()
        var lastTotalTokens: Int?
        let compactor = ContextCompactor(
            client: client, toolDefinitions: toolDefinitions, configuration: configuration
        )
        var budgetPhase = try makeBudgetPhase()

        for iteration in 1 ... configuration.maxIterations {
            try Task.checkCancellation()

            await compactor.compactOrTruncateIfNeeded(
                &messages, lastTotalTokens: lastTotalTokens, totalUsage: &totalUsage
            )
            let response = try await client.generate(
                messages: messages,
                tools: toolDefinitions,
                responseFormat: nil,
                requestContext: requestContext
            )
            messages.append(.assistant(response))
            if let usage = response.tokenUsage {
                totalUsage += usage
                lastTotalTokens = usage.total
            }
            let budgetUsage = try requireBudgetUsage(response.tokenUsage, budgetPhase: budgetPhase)

            if let finishCall = response.toolCalls.first(where: { $0.name == "finish" }) {
                return try parseFinishResult(
                    finishCall,
                    tokenUsage: totalUsage,
                    iterations: iteration,
                    history: messages
                )
            }

            if let tokenBudget, totalUsage.total > tokenBudget {
                throw AgentError.tokenBudgetExceeded(budget: tokenBudget, used: totalUsage.total)
            }

            let pruneCalls = response.toolCalls.filter { $0.name == "prune_context" }
            let regularCalls = response.toolCalls.filter { $0.name != "finish" && $0.name != "prune_context" }

            executePruneCalls(pruneCalls, messages: &messages)
            try await executeAndAppendResults(regularCalls, context: context, messages: &messages)
            if let budgetUsage {
                applyBudgetPhase(&budgetPhase, usage: budgetUsage, messages: &messages)
            }
        }

        throw AgentError.maxIterationsReached(iterations: configuration.maxIterations)
    }

    func stream(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        systemPromptOverride: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            userMessage: .user(userMessage), history: history, context: context,
            tokenBudget: tokenBudget, requestContext: nil, systemPromptOverride: systemPromptOverride
        )
    }
}

private extension Agent {
    func stream(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        tokenBudget: Int?,
        requestContext: RequestContext?,
        systemPromptOverride: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        if let tokenBudget { precondition(tokenBudget >= 1, "tokenBudget must be at least 1") }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        userMessage: userMessage,
                        history: history,
                        context: context,
                        tokenBudget: tokenBudget,
                        requestContext: requestContext,
                        systemPromptOverride: systemPromptOverride,
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
        tokenBudget: Int?,
        requestContext: RequestContext?,
        systemPromptOverride: String?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var messages = buildInitialMessages(
            userMessage: userMessage, history: history, systemPromptOverride: systemPromptOverride
        )
        var totalUsage = TokenUsage()
        var lastTotalTokens: Int?
        let policy = StreamPolicy.agent
        let processor = StreamProcessor(client: client, toolDefinitions: toolDefinitions, policy: policy)
        let compactor = ContextCompactor(
            client: client, toolDefinitions: toolDefinitions, configuration: configuration
        )
        var budgetPhase = try makeBudgetPhase()

        for iterationNumber in 1 ... configuration.maxIterations {
            try Task.checkCancellation()

            let compacted = await compactor.compactOrTruncateIfNeeded(
                &messages, lastTotalTokens: lastTotalTokens, totalUsage: &totalUsage
            )
            if compacted, let totalTokens = lastTotalTokens, let windowSize = client.contextWindowSize {
                continuation.yield(.compacted(totalTokens: totalTokens, windowSize: windowSize))
            }
            let iteration = try await processor.process(
                messages: messages,
                totalUsage: &totalUsage,
                continuation: continuation,
                requestContext: requestContext
            )

            if let usage = iteration.usage {
                lastTotalTokens = usage.total
                continuation.yield(.iterationCompleted(usage: usage, iteration: iterationNumber))
            }

            let reasoning = iteration.reasoning.isEmpty ? nil : ReasoningContent(content: iteration.reasoning)
            let details = iteration.reasoningDetails.isEmpty ? nil : iteration.reasoningDetails
            messages.append(.assistant(AssistantMessage(
                content: iteration.effectiveContent,
                toolCalls: iteration.toolCalls,
                reasoning: reasoning,
                reasoningDetails: details
            )))

            let filteredTools = policy.executableToolCalls(from: iteration.toolCalls)
            let pruneCalls = filteredTools.filter { $0.name == "prune_context" }
            let regularCalls = filteredTools.filter { $0.name != "prune_context" }
            let shouldTerminate = policy.shouldTerminateAfterIteration(toolCalls: iteration.toolCalls)
            let budgetUsage = try requireBudgetUsage(iteration.usage, budgetPhase: budgetPhase)

            executePruneCalls(pruneCalls, messages: &messages, continuation: continuation)
            try await executeStreamingAndAppendResults(
                regularCalls, context: context, messages: &messages, continuation: continuation
            )
            if let budgetUsage {
                applyBudgetPhase(
                    &budgetPhase,
                    usage: budgetUsage,
                    messages: &messages,
                    continuation: continuation
                )
            }

            if shouldTerminate {
                let finishEvent = try parseFinishEvent(
                    from: iteration.toolCalls, tokenUsage: totalUsage, history: messages
                )
                continuation.yield(finishEvent)
                continuation.finish()
                return
            }

            if let tokenBudget, totalUsage.total > tokenBudget {
                continuation.finish(
                    throwing: AgentError.tokenBudgetExceeded(budget: tokenBudget, used: totalUsage.total)
                )
                return
            }
        }

        continuation.finish(throwing: AgentError.maxIterationsReached(iterations: configuration.maxIterations))
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
        from toolCalls: [ToolCall], tokenUsage: TokenUsage, history: [ChatMessage]
    ) throws -> StreamEvent {
        guard let finishCall = toolCalls.first(where: { $0.name == "finish" }) else {
            return .finished(tokenUsage: tokenUsage, content: nil, reason: nil, history: history)
        }
        let decoded: FinishArguments
        do {
            decoded = try JSONDecoder().decode(FinishArguments.self, from: finishCall.argumentsData)
        } catch {
            throw AgentError.finishDecodingFailed(message: String(describing: error))
        }
        return .finished(
            tokenUsage: tokenUsage,
            content: decoded.content,
            reason: FinishReason(decoded.reason ?? "completed"),
            history: history
        )
    }

    func parseFinishResult(
        _ call: ToolCall,
        tokenUsage: TokenUsage,
        iterations: Int,
        history: [ChatMessage]
    ) throws -> AgentResult {
        let data = call.argumentsData
        let decoded: FinishArguments
        do {
            decoded = try JSONDecoder().decode(FinishArguments.self, from: data)
        } catch {
            throw AgentError.finishDecodingFailed(message: String(describing: error))
        }
        return AgentResult(
            finishReason: FinishReason(decoded.reason ?? "completed"),
            content: decoded.content,
            totalTokenUsage: tokenUsage,
            iterations: iterations,
            history: history
        )
    }
}
