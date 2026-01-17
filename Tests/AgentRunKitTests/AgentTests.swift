import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct AgentTests {
    @Test
    func basicCompletion() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "Done!", "reason": "success"}"#
        )
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall], tokenUsage: TokenUsage(input: 10, output: 5))
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())

        #expect(result.content == "Done!")
        #expect(result.finishReason == .custom("success"))
        #expect(result.iterations == 1)
        #expect(result.totalTokenUsage.input == 10)
        #expect(result.totalTokenUsage.output == 5)
    }

    @Test
    func finishWithNoReasonDefaultsToCompleted() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "Result"}"#
        )
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let result = try await agent.run(userMessage: "Test", context: EmptyContext())

        #expect(result.finishReason == .completed)
    }

    @Test
    func multiTurnWithToolCalls() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let toolCall = ToolCall(
            id: "call_1",
            name: "echo",
            arguments: #"{"message": "hello"}"#
        )
        let finishCall = ToolCall(
            id: "call_2",
            name: "finish",
            arguments: #"{"content": "Completed after echo"}"#
        )

        let client = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall], tokenUsage: TokenUsage(input: 10, output: 5)),
            AssistantMessage(content: "", toolCalls: [finishCall], tokenUsage: TokenUsage(input: 20, output: 10))
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])
        let result = try await agent.run(userMessage: "Use echo", context: EmptyContext())

        #expect(result.content == "Completed after echo")
        #expect(result.iterations == 2)
        #expect(result.totalTokenUsage.input == 30)
        #expect(result.totalTokenUsage.output == 15)

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 3)
        guard case let .tool(id, name, content) = capturedMessages[2] else {
            Issue.record("Expected tool message as third message")
            return
        }
        #expect(id == "call_1")
        #expect(name == "echo")
        #expect(content.contains("Echo: hello"))
    }

    @Test
    func multipleToolCallsInOneResponse() async throws {
        let addTool = try Tool<AddParams, AddOutput, EmptyContext>(
            name: "add",
            description: "Adds numbers",
            executor: { params, _ in AddOutput(sum: params.lhs + params.rhs) }
        )

        let call1 = ToolCall(id: "call_1", name: "add", arguments: #"{"lhs": 1, "rhs": 2}"#)
        let call2 = ToolCall(id: "call_2", name: "add", arguments: #"{"lhs": 3, "rhs": 4}"#)
        let finishCall = ToolCall(id: "call_3", name: "finish", arguments: #"{"content": "Both sums computed"}"#)

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [call1, call2]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [addTool])
        let result = try await agent.run(userMessage: "Add stuff", context: EmptyContext())

        #expect(result.content == "Both sums computed")
        #expect(result.iterations == 2)
    }

    @Test
    func maxIterationsReached() async throws {
        let toolCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "Does nothing",
            executor: { _, _ in NoopOutput() }
        )

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [toolCall])
        ])

        let config = AgentConfiguration(maxIterations: 3)
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)

        do {
            _ = try await agent.run(userMessage: "Loop", context: EmptyContext())
            Issue.record("Expected maxIterationsReached error")
        } catch let error as AgentError {
            guard case let .maxIterationsReached(iterations) = error else {
                Issue.record("Expected maxIterationsReached, got \(error)")
                return
            }
            #expect(iterations == 3)
        }
    }

    @Test
    func cancellationRespected() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            executor: { _, _ in
                try await Task.sleep(for: .seconds(10))
                return NoopOutput()
            }
        )
        let toolCall = ToolCall(id: "call_1", name: "slow", arguments: "{}")
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall])
        ])
        let config = AgentConfiguration(toolTimeout: .seconds(60))
        let agent = Agent<EmptyContext>(client: client, tools: [slowTool], configuration: config)

        let task = Task {
            try await agent.run(userMessage: "Go slow", context: EmptyContext())
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected
        }
    }

    @Test
    func toolTimeoutFeedsErrorToLLM() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            executor: { _, _ in
                try await Task.sleep(for: .seconds(10))
                return NoopOutput()
            }
        )
        let toolCall = ToolCall(id: "call_1", name: "slow", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "recovered"}"#)
        let client = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let config = AgentConfiguration(toolTimeout: .milliseconds(50))
        let agent = Agent<EmptyContext>(client: client, tools: [slowTool], configuration: config)

        let result = try await agent.run(userMessage: "Timeout", context: EmptyContext())
        #expect(result.content == "recovered")

        let capturedMessages = await client.capturedMessages
        let toolMessage = capturedMessages.compactMap { msg -> (String, String)? in
            guard case let .tool(_, name, content) = msg else { return nil }
            return (name, content)
        }.last
        #expect(toolMessage?.0 == "slow")
        #expect(toolMessage?.1.contains("timed out") == true)
    }

    @Test
    func systemPromptIncluded() async throws {
        let client = CapturingMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
            ])]
        )
        let config = AgentConfiguration(systemPrompt: "You are helpful.")
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        _ = try await agent.run(userMessage: "Hi", context: EmptyContext())

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 2)
        guard case let .system(prompt) = capturedMessages[0] else {
            Issue.record("Expected system message first")
            return
        }
        #expect(prompt == "You are helpful.")
        guard case let .user(content) = capturedMessages[1] else {
            Issue.record("Expected user message second")
            return
        }
        #expect(content == "Hi")
    }

    @Test
    func noSystemPromptWhenNil() async throws {
        let client = CapturingMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
            ])]
        )
        let agent = Agent<EmptyContext>(client: client, tools: [])
        _ = try await agent.run(userMessage: "Hi", context: EmptyContext())

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 1)
        guard case .user = capturedMessages[0] else {
            Issue.record("Expected user message only")
            return
        }
    }
}

private struct EchoParams: Codable, SchemaProviding, Sendable {
    let message: String
    static var jsonSchema: JSONSchema { .object(properties: ["message": .string()], required: ["message"]) }
}

private struct EchoOutput: Codable, Sendable {
    let echoed: String
}

private struct AddParams: Codable, SchemaProviding, Sendable {
    let lhs: Int
    let rhs: Int

    static var jsonSchema: JSONSchema {
        .object(properties: ["lhs": .integer(), "rhs": .integer()], required: ["lhs", "rhs"])
    }
}

private struct AddOutput: Codable, Sendable {
    let sum: Int
}

private struct NoopParams: Codable, SchemaProviding, Sendable {
    static var jsonSchema: JSONSchema { .object(properties: [:], required: []) }
}

private struct NoopOutput: Codable, Sendable {}

actor CapturingMockLLMClient: LLMClient {
    private let responses: [AssistantMessage]
    private var callIndex: Int = 0
    private(set) var capturedMessages: [ChatMessage] = []

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        capturedMessages = messages
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses available"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
