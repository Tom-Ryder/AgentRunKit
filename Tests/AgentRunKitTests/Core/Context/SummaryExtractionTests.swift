@testable import AgentRunKit
import Testing

private let noopCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")
private let finishCall = ToolCall(
    id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#
)

private func makeNoopTool() throws -> Tool<NoopParams, NoopOutput, EmptyContext> {
    try Tool(name: "noop", description: "No-op", executor: { _, _ in NoopOutput() })
}

private actor ExtractionMockLLMClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("ExtractionMockLLMClient")
    let contextWindowSize: Int?
    private let responses: [AssistantMessage]
    private var callIndex = 0
    private(set) var allCapturedMessages: [[ChatMessage]] = []

    init(responses: [AssistantMessage], contextWindowSize: Int?) {
        self.responses = responses
        self.contextWindowSize = contextWindowSize
    }

    func generate(
        messages: [ChatMessage], tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?, requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        allCapturedMessages.append(messages)
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage], tools _: [ToolDefinition], requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

struct SummaryExtractionTests {
    @Test
    func extractsSummaryFromTaggedResponse() async throws {
        let client = ExtractionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "Using tool", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 500, output: 250)
                ),
                AssistantMessage(
                    content: "<analysis>\nReasoning here\n</analysis>\n<summary>\nClean summary.\n</summary>",
                    tokenUsage: TokenUsage(input: 50, output: 100)
                ),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 100, output: 50)
                ),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.7)
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        _ = try await agent.run(userMessage: "Hello", context: EmptyContext())

        let allMessages = await client.allCapturedMessages
        let bridgeMessage = allMessages[2].first {
            if case let .user(text) = $0 { return text.contains("Context Continuation") }
            return false
        }
        guard case let .user(bridgeText) = bridgeMessage else {
            Issue.record("Expected bridge message"); return
        }
        #expect(bridgeText.contains("Clean summary."))
        #expect(!bridgeText.contains("<analysis>"))
        #expect(!bridgeText.contains("Reasoning here"))
    }

    @Test
    func fallsBackToFullResponseWhenNoTags() async throws {
        let client = ExtractionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "Using tool", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 500, output: 250)
                ),
                AssistantMessage(
                    content: "Plain summary without tags.",
                    tokenUsage: TokenUsage(input: 50, output: 100)
                ),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 100, output: 50)
                ),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.7)
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        _ = try await agent.run(userMessage: "Hello", context: EmptyContext())

        let allMessages = await client.allCapturedMessages
        let bridgeMessage = allMessages[2].first {
            if case let .user(text) = $0 { return text.contains("Context Continuation") }
            return false
        }
        guard case let .user(bridgeText) = bridgeMessage else {
            Issue.record("Expected bridge message"); return
        }
        #expect(bridgeText.contains("Plain summary without tags."))
    }
}

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}
