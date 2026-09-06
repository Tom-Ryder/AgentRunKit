import Foundation

extension Agent {
    func yieldIterationCompleted(
        iteration: StreamIteration,
        iterationNumber: Int,
        messages: [ChatMessage],
        context: C,
        eventFactory: StreamEventFactory,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        continuation.yield(eventFactory.make(.iterationCompleted(
            usage: iteration.usage,
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
