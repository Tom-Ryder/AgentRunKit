@testable import AgentRunKit
import Testing

private let promptTooLongError = AgentError.llmError(
    .httpError(statusCode: 400, body: "context_length_exceeded")
)

private enum GenerateStep {
    case response(AssistantMessage)
    case error(any Error)
}

private actor ChatRecoveryMockClient: LLMClient {
    private let generateSteps: [GenerateStep]
    private let streamSteps: [StreamStep]
    private var generateIndex = 0
    private var streamIndex = 0

    init(generateSteps: [GenerateStep] = [], streamSteps: [StreamStep] = []) {
        self.generateSteps = generateSteps
        self.streamSteps = streamSteps
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        defer { generateIndex += 1 }
        guard generateIndex < generateSteps.count else {
            throw AgentError.llmError(.other("No more generate steps"))
        }
        switch generateSteps[generateIndex] {
        case let .response(msg):
            return msg
        case let .error(err):
            throw err
        }
    }

    func nextStreamStep() -> StreamStep {
        let step = streamIndex < streamSteps.count ? streamSteps[streamIndex] : .deltas([])
        streamIndex += 1
        return step
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let step = await self.nextStreamStep()
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

private enum StreamStep {
    case deltas([StreamDelta])
    case error(any Error)
    case deltasThenError([StreamDelta], any Error)
}

struct ChatSendRecoveryTests {
    @Test
    func sendRecoversFromPromptTooLongViaTruncation() async throws {
        let client = ChatRecoveryMockClient(generateSteps: [
            .error(promptTooLongError),
            .response(AssistantMessage(content: "recovered")),
        ])
        let chat = Chat<EmptyContext>(client: client)
        let history: [ChatMessage] = [
            .user("old"),
            .assistant(AssistantMessage(content: "reply")),
            .user("more"),
            .assistant(AssistantMessage(content: "another")),
        ]

        let (response, recoveredHistory) = try await chat.send("Go", history: history)
        #expect(response.content == "recovered")
        #expect(recoveredHistory.count < history.count + 2)
    }

    @Test
    func sendPropagatesWhenAlreadyMinimal() async throws {
        let client = ChatRecoveryMockClient(generateSteps: [
            .error(promptTooLongError),
        ])
        let chat = Chat<EmptyContext>(client: client)

        await #expect(throws: AgentError.self) {
            _ = try await chat.send("Go")
        }
    }

    @Test
    func sendStructuredOutputRecoversFromPromptTooLong() async throws {
        let client = ChatRecoveryMockClient(generateSteps: [
            .error(promptTooLongError),
            .response(AssistantMessage(content: #"{"value":"recovered"}"#)),
        ])
        let chat = Chat<EmptyContext>(client: client)
        let history: [ChatMessage] = [
            .user("old"),
            .assistant(AssistantMessage(content: "reply")),
            .user("more"),
            .assistant(AssistantMessage(content: "another")),
        ]

        let (result, _) = try await chat.send(
            "Go", history: history, returning: ChatRecoveryTestOutput.self
        )
        #expect(result.value == "recovered")
    }
}

struct ChatStreamRecoveryTests {
    @Test
    func streamRecoversFromPromptTooLongBeforeOutput() async throws {
        let client = ChatRecoveryMockClient(streamSteps: [
            .error(promptTooLongError),
            .deltas([
                .content("recovered"),
                .finished(usage: TokenUsage(input: 10, output: 5)),
            ]),
        ])
        let chat = Chat<EmptyContext>(client: client)
        let history: [ChatMessage] = [
            .user("old"),
            .assistant(AssistantMessage(content: "reply")),
            .user("more"),
            .assistant(AssistantMessage(content: "another")),
        ]

        var events: [StreamEvent] = []
        for try await event in chat.stream("Go", history: history, context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.contains { $0.kind == .delta("recovered") })
    }

    @Test
    func streamNoRetryAfterOutputEmitted() async throws {
        let client = ChatRecoveryMockClient(streamSteps: [
            .deltasThenError([.content("partial")], promptTooLongError),
        ])
        let chat = Chat<EmptyContext>(client: client)

        await #expect(throws: AgentError.self) {
            for try await _ in chat.stream("Go", context: EmptyContext()) {}
        }
    }

    @Test
    func streamPropagatesWhenAlreadyMinimal() async throws {
        let client = ChatRecoveryMockClient(streamSteps: [
            .error(promptTooLongError),
        ])
        let chat = Chat<EmptyContext>(client: client)

        await #expect(throws: AgentError.self) {
            for try await _ in chat.stream("Go", context: EmptyContext()) {}
        }
    }
}

private struct ChatRecoveryTestOutput: Codable, SchemaProviding {
    let value: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["value": .string()], required: ["value"])
    }
}
