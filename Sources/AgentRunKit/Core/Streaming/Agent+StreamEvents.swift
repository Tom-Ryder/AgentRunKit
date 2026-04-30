import Foundation

extension Agent {
    func tryFinishOnTerminalEvent(
        iteration: StreamIteration,
        totalUsage: TokenUsage,
        history: [ChatMessage],
        eventFactory: StreamEventFactory,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) throws -> Bool {
        if let finishCall = try exclusiveFinishCall(in: iteration.toolCalls) {
            try finishStreaming(
                continuation: continuation,
                event: parseFinishEvent(
                    from: finishCall, tokenUsage: totalUsage,
                    history: history, eventFactory: eventFactory
                )
            )
            return true
        }
        if shouldTerminateOnContent(
            client: client,
            toolCalls: iteration.toolCalls,
            content: iteration.effectiveContent
        ) {
            try finishStreaming(
                continuation: continuation,
                event: makeFinishedEvent(
                    tokenUsage: totalUsage,
                    content: iteration.effectiveContent,
                    reason: .completed,
                    history: history.sanitizedTerminalHistory(),
                    eventFactory: eventFactory
                )
            )
            return true
        }
        return false
    }

    func yieldIterationCompletedIfPossible(
        iteration: StreamIteration,
        iterationNumber: Int,
        messages: [ChatMessage],
        context: C,
        eventFactory: StreamEventFactory,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        guard let usage = iteration.usage else { return }
        continuation.yield(eventFactory.make(.iterationCompleted(
            usage: usage,
            iteration: iterationNumber,
            history: emittedIterationHistory(messages: messages, context: context)
        )))
    }

    func emittedIterationHistory(messages: [ChatMessage], context: C) -> [ChatMessage] {
        guard let limit = configuration.historyEmissionDepthLimit else {
            return messages
        }
        let depth = currentDepth(of: context)
        return depth > limit ? [] : messages
    }

    func applyHistoryEmissionLimitToSubAgentEvent(_ event: StreamEvent, parentDepth: Int) -> StreamEvent {
        guard let limit = configuration.historyEmissionDepthLimit else { return event }
        return rewritingHistoryEmission(in: event, depth: parentDepth + 1, limit: limit)
    }

    private func rewritingHistoryEmission(in event: StreamEvent, depth: Int, limit: Int) -> StreamEvent {
        switch event.kind {
        case let .iterationCompleted(usage, iteration, history) where depth > limit && !history.isEmpty:
            return StreamEvent(
                id: event.id, timestamp: event.timestamp,
                sessionID: event.sessionID, runID: event.runID,
                parentEventID: event.parentEventID, origin: event.origin,
                kind: .iterationCompleted(usage: usage, iteration: iteration, history: [])
            )
        case let .subAgentEvent(toolCallId, toolName, nested):
            let rewritten = rewritingHistoryEmission(in: nested, depth: depth + 1, limit: limit)
            return StreamEvent(
                id: event.id, timestamp: event.timestamp,
                sessionID: event.sessionID, runID: event.runID,
                parentEventID: event.parentEventID, origin: event.origin,
                kind: .subAgentEvent(toolCallId: toolCallId, toolName: toolName, event: rewritten)
            )
        default:
            return event
        }
    }

    func parseFinishEvent(
        from finishCall: ToolCall,
        tokenUsage: TokenUsage,
        history: [ChatMessage],
        eventFactory: StreamEventFactory
    ) throws -> StreamEvent {
        let decoded = try decodeFinishArguments(from: finishCall.argumentsData)
        return try makeFinishedEvent(
            tokenUsage: tokenUsage,
            content: decoded.content,
            reason: FinishReason(decoded.reason ?? "completed"),
            history: history.sanitizedTerminalHistory(),
            eventFactory: eventFactory
        )
    }

    func makeFinishedEvent(
        tokenUsage: TokenUsage,
        content: String?,
        reason: FinishReason?,
        history: [ChatMessage],
        eventFactory: StreamEventFactory
    ) -> StreamEvent {
        eventFactory.make(.finished(
            tokenUsage: tokenUsage,
            content: content,
            reason: reason,
            history: history
        ))
    }

    func emitCompactionEventIfNeeded(
        _ compacted: Bool,
        lastTotalTokens: Int?,
        eventFactory: StreamEventFactory,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        guard compacted, let totalTokens = lastTotalTokens, let windowSize = client.contextWindowSize else {
            return
        }
        continuation.yield(eventFactory.make(.compacted(totalTokens: totalTokens, windowSize: windowSize)))
    }

    func exclusiveFinishCall(in toolCalls: [ToolCall]) throws -> ToolCall? {
        let finishCalls = toolCalls.filter { $0.name == "finish" }
        guard !finishCalls.isEmpty else { return nil }
        guard finishCalls.count == 1, toolCalls.count == 1 else {
            throw AgentError.malformedHistory(.finishMustBeExclusive)
        }
        return finishCalls[0]
    }

    func finishIfOverBudget(
        _ tokenBudget: Int?,
        totalUsage: TokenUsage,
        history: [ChatMessage],
        eventFactory: StreamEventFactory,
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
                history: history,
                eventFactory: eventFactory
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
