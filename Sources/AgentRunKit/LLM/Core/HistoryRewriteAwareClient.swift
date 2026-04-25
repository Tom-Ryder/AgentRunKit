import Foundation

enum RunRequestMode: Equatable {
    case auto
    case forceFullRequest
}

enum RunStreamElement {
    case delta(StreamDelta)
    case finalizedContinuity(AssistantContinuity)
}

protocol HistoryRewriteAwareClient: LLMClient {
    func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?,
        requestMode: RunRequestMode
    ) async throws -> AssistantMessage

    func streamForRun(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?,
        requestMode: RunRequestMode
    ) -> AsyncThrowingStream<RunStreamElement, Error>
}

extension HistoryRewriteAwareClient {
    func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?,
        requestMode _: RunRequestMode
    ) async throws -> AssistantMessage {
        try await generate(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            requestContext: requestContext
        )
    }

    func streamForRun(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?,
        requestMode _: RunRequestMode
    ) -> AsyncThrowingStream<RunStreamElement, Error> {
        wrapRunStream(stream(messages: messages, tools: tools, requestContext: requestContext))
    }
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

    func streamForRun(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?,
        requestMode: RunRequestMode
    ) -> AsyncThrowingStream<RunStreamElement, Error> {
        if let capableClient = self as? any HistoryRewriteAwareClient {
            return capableClient.streamForRun(
                messages: messages,
                tools: tools,
                requestContext: requestContext,
                requestMode: requestMode
            )
        }
        return wrapRunStream(stream(messages: messages, tools: tools, requestContext: requestContext))
    }
}

private func wrapRunStream(
    _ stream: AsyncThrowingStream<StreamDelta, Error>
) -> AsyncThrowingStream<RunStreamElement, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await delta in stream {
                    continuation.yield(.delta(delta))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}
