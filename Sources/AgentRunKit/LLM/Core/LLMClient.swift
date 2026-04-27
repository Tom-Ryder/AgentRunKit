import Foundation

/// The interface all LLM provider clients conform to.
///
/// For provider-specific setup, see <doc:LLMProviders>.
public protocol LLMClient: Sendable {
    var contextWindowSize: Int? { get }
    var providerIdentifier: ProviderIdentifier { get }

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
    var contextWindowSize: Int? {
        nil
    }

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
