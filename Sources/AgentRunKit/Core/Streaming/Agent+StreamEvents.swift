import Foundation

extension Agent {
    func parseFinishEvent(
        from finishCall: ToolCall,
        tokenUsage: TokenUsage,
        history: [ChatMessage],
        eventFactory: StreamEventFactory
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
