import Foundation

public struct AssistantMessage: Sendable, Equatable, Codable {
    public let content: String
    public let toolCalls: [ToolCall]
    public let tokenUsage: TokenUsage?
    public let reasoning: ReasoningContent?
    public let reasoningDetails: [JSONValue]?

    public init(
        content: String,
        toolCalls: [ToolCall] = [],
        tokenUsage: TokenUsage? = nil,
        reasoning: ReasoningContent? = nil,
        reasoningDetails: [JSONValue]? = nil
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.tokenUsage = tokenUsage
        self.reasoning = reasoning
        self.reasoningDetails = reasoningDetails
    }
}
