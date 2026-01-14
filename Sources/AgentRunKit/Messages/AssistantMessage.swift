import Foundation

public struct AssistantMessage: Sendable, Equatable, Codable {
    public let content: String
    public let toolCalls: [ToolCall]
    public let tokenUsage: TokenUsage?

    public init(content: String, toolCalls: [ToolCall] = [], tokenUsage: TokenUsage? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.tokenUsage = tokenUsage
    }
}
