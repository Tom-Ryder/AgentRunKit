import Foundation

public enum StreamEvent: Sendable, Equatable {
    case delta(String)
    case toolCallStarted(name: String, id: String)
    case toolCallCompleted(id: String, name: String, result: ToolResult)
    case finished(tokenUsage: TokenUsage, content: String?, reason: FinishReason?)
}
