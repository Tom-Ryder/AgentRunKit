@testable import AgentRunKit

actor CompactionMockLLMClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("CompactionMockLLMClient")
    let contextWindowSize: Int?
    private let responses: [AssistantMessage]
    private var callIndex: Int = 0
    private(set) var allCapturedMessages: [[ChatMessage]] = []
    private(set) var allCapturedTools: [[ToolDefinition]] = []
    private(set) var generateCallCount: Int = 0
    private let failSummarization: Bool

    init(
        responses: [AssistantMessage],
        contextWindowSize: Int? = nil,
        failSummarization: Bool = false
    ) {
        self.responses = responses
        self.contextWindowSize = contextWindowSize
        self.failSummarization = failSummarization
    }

    func generate(
        messages: [ChatMessage], tools: [ToolDefinition],
        responseFormat _: ResponseFormat?, requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        generateCallCount += 1
        allCapturedTools.append(tools)
        if failSummarization, case let .user(text) = messages.last,
           text.contains("CONTEXT CHECKPOINT") {
            throw AgentError.llmError(.other("Summarization failed"))
        }
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

let compactionNoopCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")

func hasCompactionBridge(_ messages: [ChatMessage]) -> Bool {
    messages.contains {
        if case let .user(text) = $0 { text.contains("Context Continuation") } else { false }
    }
}
