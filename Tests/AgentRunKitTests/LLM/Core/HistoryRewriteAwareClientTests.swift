@testable import AgentRunKit
import Foundation
import Testing

private actor HistoryRewriteFallbackMockLLMClient: LLMClient, HistoryRewriteAwareClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("HistoryRewriteFallbackMockLLMClient")
    private let response: AssistantMessage

    init(response: AssistantMessage) {
        self.response = response
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        response
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?,
        requestMode _: RunRequestMode
    ) async throws -> AssistantMessage {
        response
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let (stream, continuation) = AsyncThrowingStream<StreamDelta, Error>.makeStream()
        continuation.yield(.content("history-aware fallback"))
        continuation.finish()
        return stream
    }
}

struct HistoryRewriteAwareClientTests {
    @Test
    func streamForRunFallsBackToPlainStreamWithoutRecursing() async throws {
        let client = HistoryRewriteFallbackMockLLMClient(
            response: AssistantMessage(content: "")
        )
        let erasedClient: any LLMClient = client

        var collected = ""
        for try await element in erasedClient.streamForRun(
            messages: [.user("Hi")],
            tools: [],
            requestContext: nil,
            requestMode: .forceFullRequest
        ) {
            if case let .delta(.content(text)) = element {
                collected += text
            }
        }

        #expect(collected == "history-aware fallback")
    }
}
