@testable import AgentRunKit
import Testing

private let promptTooLongError = AgentError.llmError(
    .httpError(statusCode: 400, body: "context_length_exceeded")
)

private enum StreamStep {
    case deltas([StreamDelta])
    case error(any Error)
    case deltasThenError([StreamDelta], any Error)
}

private actor ErrorInjectingStreamClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("ErrorInjectingStreamClient")
    let contextWindowSize: Int?
    private let steps: [StreamStep]
    private let generateResponses: [AssistantMessage]
    private var stepIndex = 0
    private var generateIndex = 0

    init(
        steps: [StreamStep],
        generateResponses: [AssistantMessage] = [],
        contextWindowSize: Int? = nil
    ) {
        self.steps = steps
        self.generateResponses = generateResponses
        self.contextWindowSize = contextWindowSize
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        defer { generateIndex += 1 }
        guard generateIndex < generateResponses.count else {
            throw AgentError.llmError(.other("No more generate responses"))
        }
        return generateResponses[generateIndex]
    }

    func nextStep() -> StreamStep {
        let step = stepIndex < steps.count ? steps[stepIndex] : .deltas([])
        stepIndex += 1
        return step
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let step = await self.nextStep()
                switch step {
                case let .deltas(deltas):
                    for delta in deltas {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                case let .error(error):
                    continuation.finish(throwing: error)
                case let .deltasThenError(deltas, error):
                    for delta in deltas {
                        continuation.yield(delta)
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

struct AgentStreamingRecoveryTests {
    @Test
    func streamingRecoveryOnPromptTooLongBeforeOutput() async throws {
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"recovered"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let summaryResponse = AssistantMessage(
            content: "Summary of earlier work",
            tokenUsage: TokenUsage(input: 20, output: 10)
        )
        let client = ErrorInjectingStreamClient(
            steps: [.error(promptTooLongError), .deltas(finishDeltas)],
            generateResponses: [summaryResponse],
            contextWindowSize: 1000
        )
        let agent = Agent<EmptyContext>(
            client: client,
            tools: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        let history: [ChatMessage] = [
            .user("earlier"),
            .assistant(AssistantMessage(content: "reply")),
            .user("more"),
            .assistant(AssistantMessage(content: "another")),
        ]

        var events: [StreamEvent] = []
        for try await event in agent.stream(
            userMessage: "Go", history: history, context: EmptyContext()
        ) {
            events.append(event)
        }

        guard case let .finished(_, content, _, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "recovered")
    }

    @Test
    func streamingNoRetryAfterOutputEmitted() async throws {
        let client = ErrorInjectingStreamClient(
            steps: [.deltasThenError([.content("partial")], promptTooLongError)],
            contextWindowSize: 1000
        )
        let agent = Agent<EmptyContext>(
            client: client,
            tools: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )

        await #expect(throws: AgentError.self) {
            for try await _ in agent.stream(userMessage: "Go", context: EmptyContext()) {}
        }
    }

    @Test
    func sameTurnSecondOverflowRethrows() async throws {
        let summaryResponse = AssistantMessage(
            content: "Summary",
            tokenUsage: TokenUsage(input: 10, output: 5)
        )
        let client = ErrorInjectingStreamClient(
            steps: [.error(promptTooLongError), .error(promptTooLongError)],
            generateResponses: [summaryResponse],
            contextWindowSize: 1000
        )
        let agent = Agent<EmptyContext>(
            client: client,
            tools: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        let history: [ChatMessage] = [
            .user("earlier"),
            .assistant(AssistantMessage(content: "reply")),
            .user("more"),
            .assistant(AssistantMessage(content: "another")),
        ]

        await #expect(throws: AgentError.self) {
            for try await _ in agent.stream(
                userMessage: "Go", history: history, context: EmptyContext()
            ) {}
        }
    }
}
