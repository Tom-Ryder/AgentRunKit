@testable import AgentRunKit
import Testing

private actor SummaryMockLLMClient: LLMClient {
    let contextWindowSize: Int?
    private let responses: [AssistantMessage]
    private var callIndex = 0
    private(set) var generateCallCount = 0
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
        messages: [ChatMessage], tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?, requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        generateCallCount += 1
        if failSummarization, case let .user(text) = messages.last,
           text.contains("CONTEXT CHECKPOINT") {
            throw AgentError.llmError(.other("Summarization failed"))
        }
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

struct ReactiveSummaryCompactionTests {
    @Test
    func summaryTierSucceedsWhenLocalReductionFails() async throws {
        let client = SummaryMockLLMClient(
            responses: [AssistantMessage(
                content: "Summary of progress",
                tokenUsage: TokenUsage(input: 50, output: 20)
            )],
            contextWindowSize: 1000
        )
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Task"),
            .assistant(AssistantMessage(content: "short")),
            .user("Continue"),
        ]
        var totalUsage = TokenUsage()
        let outcome = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)

        #expect(outcome == .compacted)
        #expect(totalUsage.input == 50)
        #expect(totalUsage.output == 20)
        #expect(await client.generateCallCount == 1)
    }

    @Test
    func summaryTierSkippedWhenCompactionThresholdNil() async throws {
        let client = SummaryMockLLMClient(responses: [], contextWindowSize: 1000)
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration()
        )
        var messages: [ChatMessage] = [
            .user("Task"),
            .assistant(AssistantMessage(content: "short")),
            .user("Continue"),
        ]
        var totalUsage = TokenUsage()
        let outcome = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)

        #expect(outcome == .unchanged)
        #expect(await client.generateCallCount == 0)
    }

    @Test
    func summaryTierRespectsCircuitBreaker() async throws {
        let client = SummaryMockLLMClient(
            responses: [],
            contextWindowSize: 1000,
            failSummarization: true
        )
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Task"),
            .assistant(AssistantMessage(content: "short")),
            .user("Continue"),
        ]
        var totalUsage = TokenUsage()

        for _ in 0 ..< 3 {
            let outcome = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)
            #expect(outcome == .unchanged)
        }

        let trippedOutcome = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)
        #expect(trippedOutcome == .unchanged)
        #expect(await client.generateCallCount == 3)
    }

    @Test
    func summaryTierFailureIncrementsCircuitBreaker() async throws {
        let client = SummaryMockLLMClient(
            responses: [],
            contextWindowSize: 1000,
            failSummarization: true
        )
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Task"),
            .assistant(AssistantMessage(content: "short")),
            .user("Continue"),
        ]
        var totalUsage = TokenUsage()
        let outcome = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)

        #expect(outcome == .unchanged)
        #expect(await client.generateCallCount == 1)
    }
}
