import Foundation

/// Events emitted during agent streaming.
///
/// For a guide, see <doc:StreamingAndSwiftUI>.
public enum StreamEvent: Sendable, Equatable {
    case delta(String)
    case reasoningDelta(String)
    case toolCallStarted(name: String, id: String)
    case toolCallCompleted(id: String, name: String, result: ToolResult)
    case audioData(Data)
    case audioTranscript(String)
    case audioFinished(id: String, expiresAt: Int, data: Data)
    case finished(tokenUsage: TokenUsage, content: String?, reason: FinishReason?, history: [ChatMessage])
    case subAgentStarted(toolCallId: String, toolName: String)
    indirect case subAgentEvent(toolCallId: String, toolName: String, event: StreamEvent)
    case subAgentCompleted(toolCallId: String, toolName: String, result: ToolResult)
    case iterationCompleted(usage: TokenUsage, iteration: Int)
    case compacted(totalTokens: Int, windowSize: Int)
    /// Emitted after each provider response when a budget snapshot is available.
    case budgetUpdated(budget: ContextBudget)
    /// Emitted once when the configured soft threshold is crossed.
    case budgetAdvisory(budget: ContextBudget)
    case toolApprovalRequested(ToolApprovalRequest)
    case toolApprovalResolved(toolCallId: String, decision: ToolApprovalDecision)
}
