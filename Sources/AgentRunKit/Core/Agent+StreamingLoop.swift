import Foundation

struct StreamingLoopState {
    var messages: [ChatMessage]
    var historyWasRewrittenLocally: Bool = false
    var budgetPhase: ContextBudgetPhase?
    var sessionAllowlist: Set<String> = []
}

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

    func finalizeStreamingIteration(
        toolCalls: [ToolCall],
        context: C,
        budgetUsage: TokenUsage?,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        state: inout StreamingLoopState
    ) async throws {
        let indexedCalls = indexedExecutableToolCalls(from: toolCalls)
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
        appendToolResults(
            (pruneOutcome.results + regularResults).sorted { $0.index < $1.index },
            messages: &state.messages
        )

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
        requestContext: RequestContext?
    ) async throws -> StreamIteration {
        var attemptedReactiveRecovery = false

        while true {
            var emittedOutput = false
            do {
                let iteration = try await processor.process(
                    messages: messages,
                    totalUsage: &totalUsage,
                    emittedOutput: &emittedOutput,
                    continuation: continuation,
                    requestContext: requestContext,
                    requestMode: requestMode(for: historyWasRewrittenLocally)
                )
                historyWasRewrittenLocally = false
                return iteration
            } catch let AgentError.llmError(transport) where transport.isPromptTooLong {
                guard !emittedOutput, !attemptedReactiveRecovery else {
                    throw AgentError.llmError(transport)
                }
                attemptedReactiveRecovery = true
                let reactiveOutcome = try await compactor.reactiveCompact(
                    &messages,
                    totalUsage: &totalUsage,
                    summaryGenerator: makeSummaryGenerator(for: historyWasRewrittenLocally)
                )
                guard reactiveOutcome.didRewriteHistory else {
                    throw AgentError.llmError(transport)
                }
                historyWasRewrittenLocally = true
            }
        }
    }
}
