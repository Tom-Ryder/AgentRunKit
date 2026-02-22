import Foundation

public protocol LLMClient: Sendable {
    func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage

    func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error>
}

public extension LLMClient {
    func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?
    ) async throws -> AssistantMessage {
        try await generate(messages: messages, tools: tools, responseFormat: responseFormat, requestContext: nil)
    }

    func generate(messages: [ChatMessage], tools: [ToolDefinition]) async throws -> AssistantMessage {
        try await generate(messages: messages, tools: tools, responseFormat: nil, requestContext: nil)
    }

    func stream(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<StreamDelta, Error> {
        stream(messages: messages, tools: tools, requestContext: nil)
    }
}
