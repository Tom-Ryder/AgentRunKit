import Foundation

enum RunRequestMode: Equatable {
    case auto
    case forceFullRequest
}

protocol HistoryRewriteAwareClient: LLMClient {
    func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?,
        requestMode: RunRequestMode
    ) async throws -> AssistantMessage
}

extension LLMClient {
    func generateForRun(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?,
        requestMode: RunRequestMode
    ) async throws -> AssistantMessage {
        if let capableClient = self as? any HistoryRewriteAwareClient {
            return try await capableClient.generate(
                messages: messages,
                tools: tools,
                responseFormat: responseFormat,
                requestContext: requestContext,
                requestMode: requestMode
            )
        }
        return try await generate(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            requestContext: requestContext
        )
    }
}
