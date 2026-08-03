import Foundation

extension Agent {
    func executeRunIteration(
        messages: inout [ChatMessage],
        totalUsage: inout TokenUsage,
        lastTotalTokens: inout Int?,
        compactor: inout ContextCompactor,
        historyWasRewrittenLocally: inout Bool,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        let compactionOutcome = try await compactor.compactOrTruncateIfNeeded(
            &messages,
            lastTotalTokens: lastTotalTokens,
            totalUsage: &totalUsage,
            summaryGenerator: makeSummaryGenerator(for: historyWasRewrittenLocally)
        )
        if compactionOutcome.didRewriteHistory {
            historyWasRewrittenLocally = true
        }

        let response = try await generateRunResponse(
            messages: &messages,
            totalUsage: &totalUsage,
            compactor: &compactor,
            historyWasRewrittenLocally: &historyWasRewrittenLocally,
            requestContext: requestContext
        )
        messages.append(.assistant(response))
        if let usage = response.tokenUsage {
            totalUsage += usage
            lastTotalTokens = usage.total
        }
        return response
    }

    func generateRunResponse(
        messages: inout [ChatMessage],
        totalUsage: inout TokenUsage,
        compactor: inout ContextCompactor,
        historyWasRewrittenLocally: inout Bool,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        try await withPromptTooLongRecovery {
            let response = try await client.generateForRun(
                messages: messages,
                tools: toolDefinitions,
                responseFormat: nil,
                requestContext: requestContext,
                requestMode: requestMode(for: historyWasRewrittenLocally)
            )
            historyWasRewrittenLocally = false
            return response
        } recover: {
            let reactiveOutcome = try await compactor.reactiveCompact(
                &messages,
                totalUsage: &totalUsage,
                summaryGenerator: makeSummaryGenerator(for: historyWasRewrittenLocally)
            )
            guard reactiveOutcome.didRewriteHistory else { return false }
            historyWasRewrittenLocally = true
            return true
        }
    }

    func resolveRunIteration(
        response: AssistantMessage,
        context: C,
        iteration: Int,
        totalUsage: TokenUsage,
        options: InvocationOptions,
        state: inout AgentLoopState
    ) async throws -> AgentResult? {
        switch try completionPolicy.classify(response.toolCalls) {
        case let .builtInFinish(finishCall):
            return try parseFinishResult(
                finishCall,
                tokenUsage: totalUsage,
                iterations: iteration,
                history: state.messages
            )

        case let .executableCompletion(call):
            return try await completeRunIteration(
                call: call, context: context, iteration: iteration,
                totalUsage: totalUsage, budgetUsage: response.tokenUsage,
                options: options, state: &state
            )

        case let .exclusivityViolation(toolName, calls):
            return try continueRunIteration(
                results: exclusivityFeedbackResults(for: calls, toolName: toolName), iteration: iteration,
                totalUsage: totalUsage, budgetUsage: response.tokenUsage,
                options: options, state: &state
            )

        case .none:
            if completionPolicy.allowsContentOnlyTermination,
               shouldTerminateOnContent(client: client, toolCalls: response.toolCalls, content: response.content) {
                return try AgentResult(
                    finishReason: .completed,
                    content: response.content,
                    totalTokenUsage: totalUsage,
                    iterations: iteration,
                    history: state.messages.sanitizedTerminalHistory()
                )
            }
            return try await finalizeRunIteration(
                toolCalls: response.toolCalls, context: context, iteration: iteration,
                totalUsage: totalUsage, budgetUsage: response.tokenUsage,
                options: options, state: &state
            )
        }
    }

    private func completeRunIteration(
        call: ToolCall,
        context: C,
        iteration: Int,
        totalUsage: TokenUsage,
        budgetUsage: TokenUsage?,
        options: InvocationOptions,
        state: inout AgentLoopState
    ) async throws -> AgentResult? {
        switch try await executeCompletionCall(
            call, context: context, messages: state.messages,
            options: options, allowlist: &state.sessionAllowlist
        ) {
        case let .completed(outcome):
            state.messages.append(.tool(id: call.id, name: call.name, content: outcome.content))
            if let budgetUsage {
                advanceBudgetPhase(&state.budgetPhase, usage: budgetUsage)
            }
            try state.messages.validateForAgentHistory()
            return AgentResult(
                finishReason: .completed,
                content: outcome.content,
                totalTokenUsage: totalUsage,
                iterations: iteration,
                history: state.messages
            )

        case let .feedback(result):
            return try continueRunIteration(
                results: [IndexedToolResult(index: 0, call: call, result: result)],
                iteration: iteration, totalUsage: totalUsage, budgetUsage: budgetUsage,
                options: options, state: &state
            )
        }
    }

    private func finalizeRunIteration(
        toolCalls: [ToolCall],
        context: C,
        iteration: Int,
        totalUsage: TokenUsage,
        budgetUsage: TokenUsage?,
        options: InvocationOptions,
        state: inout AgentLoopState
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
        return try continueRunIteration(
            results: (pruneOutcome.results + regularResults).sorted { $0.index < $1.index },
            iteration: iteration, totalUsage: totalUsage, budgetUsage: budgetUsage,
            options: options, state: &state
        )
    }

    private func continueRunIteration(
        results: [IndexedToolResult],
        iteration: Int,
        totalUsage: TokenUsage,
        budgetUsage: TokenUsage?,
        options: InvocationOptions,
        state: inout AgentLoopState
    ) throws -> AgentResult? {
        appendToolResults(results, messages: &state.messages)
        if let budgetUsage {
            applyBudgetPhase(&state.budgetPhase, usage: budgetUsage, messages: &state.messages)
        }
        try state.messages.validateForAgentHistory()

        guard let tokenBudget = options.tokenBudget, totalUsage.total > tokenBudget else {
            return nil
        }
        return makeTerminalResult(
            reason: .tokenBudgetExceeded(budget: tokenBudget, used: totalUsage.total),
            tokenUsage: totalUsage,
            iterations: iteration,
            history: state.messages
        )
    }

    func requestMode(for historyWasRewrittenLocally: Bool) -> RunRequestMode {
        historyWasRewrittenLocally ? .forceFullRequest : .auto
    }

    func makeSummaryGenerator(
        for historyWasRewrittenLocally: Bool
    ) -> ContextCompactor.SummaryGenerator {
        let mode = requestMode(for: historyWasRewrittenLocally)
        return { summaryRequest in
            try await self.client.generateForRun(
                messages: summaryRequest,
                tools: [],
                responseFormat: nil,
                requestContext: nil,
                requestMode: mode
            )
        }
    }

    func parseFinishResult(
        _ call: ToolCall,
        tokenUsage: TokenUsage,
        iterations: Int,
        history: [ChatMessage]
    ) throws -> AgentResult {
        let decoded = try decodeFinishArguments(from: call.argumentsData)
        return try AgentResult(
            finishReason: FinishReason(decoded.reason ?? "completed"),
            content: decoded.content,
            totalTokenUsage: tokenUsage,
            iterations: iterations,
            history: history.sanitizedTerminalHistory()
        )
    }

    func makeTerminalResult(
        reason: FinishReason,
        tokenUsage: TokenUsage,
        iterations: Int,
        history: [ChatMessage]
    ) -> AgentResult {
        AgentResult(
            finishReason: reason,
            content: nil,
            totalTokenUsage: tokenUsage,
            iterations: iterations,
            history: history
        )
    }
}
