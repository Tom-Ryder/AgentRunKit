import Foundation

public protocol LLMClient: Sendable {
    func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?
    ) async throws -> AssistantMessage

    func stream(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<StreamDelta, Error>
}

public extension LLMClient {
    func generate(messages: [ChatMessage], tools: [ToolDefinition]) async throws -> AssistantMessage {
        try await generate(messages: messages, tools: tools, responseFormat: nil)
    }
}
