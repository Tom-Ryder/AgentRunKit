import Foundation

extension Agent {
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
        let depth = (context as? any CurrentDepthProviding)?.currentDepth ?? 0
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
}
