import Foundation

extension Agent {
    func compactStreamingMessagesIfNeeded(
        _ messages: inout [ChatMessage],
        totalUsage: inout TokenUsage,
        lastTotalTokens: Int?,
        compactor: inout ContextCompactor,
        historyWasRewrittenLocally: inout Bool,
        eventFactory: StreamEventFactory,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let compactionOutcome = try await compactor.compactOrTruncateIfNeeded(
            &messages,
            lastTotalTokens: lastTotalTokens,
            totalUsage: &totalUsage,
            summaryGenerator: makeSummaryGenerator(for: historyWasRewrittenLocally)
        )
        if compactionOutcome.didRewriteHistory {
            historyWasRewrittenLocally = true
        }
        emitCompactionEventIfNeeded(
            compactionOutcome.emitsCompactionEvent,
            lastTotalTokens: lastTotalTokens,
            eventFactory: eventFactory,
            continuation: continuation
        )
    }

    func resolveStreamingIteration(
        iteration: StreamIteration,
        iterationNumber: Int,
        totalUsage: TokenUsage,
        iterationContext: StreamIterationContext,
        state: inout AgentLoopState
    ) async throws -> Bool {
        let factory = iterationContext.options.eventFactory
        let continuation = iterationContext.continuation
        switch try completionPolicy.classify(iteration.toolCalls) {
        case let .builtInFinish(finishCall):
            try finishStreaming(
                continuation: continuation,
                event: parseFinishEvent(
                    from: finishCall, tokenUsage: totalUsage,
                    history: state.messages, eventFactory: factory
                )
            )
            return true

        case let .executableCompletion(call):
            return try await completeStreamingIteration(
                call: call, iteration: iteration, iterationNumber: iterationNumber,
                totalUsage: totalUsage, iterationContext: iterationContext, state: &state
            )

        case let .exclusivityViolation(toolName, calls):
            let emit = StreamEmitter(factory: factory, continuation: continuation)
            let results = exclusivityFeedbackResults(for: calls, toolName: toolName)
            for entry in results {
                emit.yield(.toolCallCompleted(
                    id: entry.call.id, name: entry.call.name, result: entry.result
                ))
            }
            try continueStreamingIteration(
                results: results, budgetUsage: iteration.usage, emit: emit, state: &state
            )
            return false

        case .none:
            if completionPolicy.allowsContentOnlyTermination,
               shouldTerminateOnContent(
                   client: client, toolCalls: iteration.toolCalls, content: iteration.effectiveContent
               ) {
                try finishStreaming(
                    continuation: continuation,
                    event: makeFinishedEvent(
                        tokenUsage: totalUsage,
                        content: iteration.effectiveContent,
                        reason: .completed,
                        history: state.messages.sanitizedTerminalHistory(),
                        eventFactory: factory
                    )
                )
                return true
            }
            try await finalizeStreamingIteration(
                toolCalls: iteration.toolCalls, context: iterationContext.context,
                budgetUsage: iteration.usage, options: iterationContext.options,
                continuation: continuation, state: &state
            )
            return false
        }
    }

    private func completeStreamingIteration(
        call: ToolCall,
        iteration: StreamIteration,
        iterationNumber: Int,
        totalUsage: TokenUsage,
        iterationContext: StreamIterationContext,
        state: inout AgentLoopState
    ) async throws -> Bool {
        let options = iterationContext.options
        let continuation = iterationContext.continuation
        let emit = StreamEmitter(factory: options.eventFactory, continuation: continuation)
        switch try await executeStreamingCompletionCall(
            call, context: iterationContext.context, messages: state.messages,
            options: options, emit: emit, allowlist: &state.sessionAllowlist
        ) {
        case let .completed(outcome):
            state.messages.append(.tool(id: call.id, name: call.name, content: outcome.content))
            if let budgetUsage = iteration.usage {
                advanceBudgetPhase(&state.budgetPhase, usage: budgetUsage, emit: emit)
            }
            try state.messages.validateForAgentHistory()
            try await checkpointIfConfigured(
                iterationNumber: iterationNumber, state: state,
                totalUsage: totalUsage, iterationUsage: iteration.usage,
                eventFactory: options.eventFactory, checkpointer: options.checkpointer,
                terminalOutcome: outcome
            )
            finishStreaming(
                continuation: continuation,
                event: makeFinishedEvent(
                    tokenUsage: totalUsage, content: outcome.content, reason: .completed,
                    history: state.messages, eventFactory: options.eventFactory
                )
            )
            return true

        case let .feedback(result):
            try continueStreamingIteration(
                results: [IndexedToolResult(index: 0, call: call, result: result)],
                budgetUsage: iteration.usage, emit: emit, state: &state
            )
            return false
        }
    }

    private func finalizeStreamingIteration(
        toolCalls: [ToolCall],
        context: C,
        budgetUsage: TokenUsage?,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        state: inout AgentLoopState
    ) async throws {
        let indexedCalls = indexedToolCalls(from: toolCalls)
        let pruneCalls = indexedCalls.filter { $0.call.name == "prune_context" }
        let regularCalls = indexedCalls.filter { $0.call.name != "prune_context" }

        let emit = StreamEmitter(factory: options.eventFactory, continuation: continuation)
        let pruneOutcome = executePruneCalls(pruneCalls, messages: &state.messages, emit: emit)
        if pruneOutcome.historyWasRewritten {
            state.historyWasRewrittenLocally = true
        }
        let regularResults = try await executeStreamingResults(
            regularCalls,
            context: context,
            messages: state.messages,
            options: options,
            continuation: continuation,
            allowlist: &state.sessionAllowlist
        )
        try continueStreamingIteration(
            results: (pruneOutcome.results + regularResults).sorted { $0.index < $1.index },
            budgetUsage: budgetUsage, emit: emit, state: &state
        )
    }

    private func continueStreamingIteration(
        results: [IndexedToolResult],
        budgetUsage: TokenUsage?,
        emit: StreamEmitter,
        state: inout AgentLoopState
    ) throws {
        appendToolResults(results, messages: &state.messages)
        if let budgetUsage {
            applyBudgetPhase(
                &state.budgetPhase, usage: budgetUsage,
                messages: &state.messages, emit: emit
            )
        }
        try state.messages.validateForAgentHistory()
    }

    func generateStreamingResponse(
        processor: StreamProcessor,
        messages: inout [ChatMessage],
        totalUsage: inout TokenUsage,
        compactor: inout ContextCompactor,
        historyWasRewrittenLocally: inout Bool,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        options: InvocationOptions
    ) async throws -> StreamIteration {
        var emittedOutput = false
        return try await withPromptTooLongRecovery {
            let iteration = try await processor.process(
                messages: messages,
                totalUsage: &totalUsage,
                emittedOutput: &emittedOutput,
                continuation: continuation,
                requestContext: options.requestContext,
                requestMode: requestMode(for: historyWasRewrittenLocally)
            )
            historyWasRewrittenLocally = false
            return iteration
        } recover: {
            guard !emittedOutput else { return false }
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
}
