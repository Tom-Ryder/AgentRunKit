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
        if client is any ContentOnlyTerminatingClient,
           iteration.toolCalls.isEmpty,
           !iteration.effectiveContent.isEmpty {
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
}
