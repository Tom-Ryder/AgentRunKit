import Foundation

func applyHistoryEmissionLimitToSubAgentEvent(_ event: StreamEvent, parentDepth: Int, limit: Int?) -> StreamEvent {
    guard let limit else { return event }
    return rewritingHistoryEmission(in: event, depth: parentDepth + 1, limit: limit)
}

private func rewritingHistoryEmission(in event: StreamEvent, depth: Int, limit: Int) -> StreamEvent {
    switch event.kind {
    case let .iterationCompleted(usage, iteration, history) where depth > limit && !history.isEmpty:
        return StreamEvent(
            id: event.id, timestamp: event.timestamp,
            sessionID: event.sessionID, runID: event.runID, origin: event.origin,
            kind: .iterationCompleted(usage: usage, iteration: iteration, history: [])
        )
    case let .subAgentEvent(toolCallId, toolName, nested):
        let rewritten = rewritingHistoryEmission(in: nested, depth: depth + 1, limit: limit)
        return StreamEvent(
            id: event.id, timestamp: event.timestamp,
            sessionID: event.sessionID, runID: event.runID, origin: event.origin,
            kind: .subAgentEvent(toolCallId: toolCallId, toolName: toolName, event: rewritten)
        )
    default:
        return event
    }
}
