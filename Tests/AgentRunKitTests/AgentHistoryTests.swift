import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct AgentHistoryTests {
    @Test
    func historyIncludedInMessages() async throws {
        let client = CapturingMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
            ])]
        )
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let history: [ChatMessage] = [
            .user("Previous question"),
            .assistant(AssistantMessage(content: "Previous answer"))
        ]
        _ = try await agent.run(userMessage: "Follow-up", history: history, context: EmptyContext())

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 3)
        guard case let .user(first) = capturedMessages[0] else {
            Issue.record("Expected user message first")
            return
        }
        #expect(first == "Previous question")
        guard case .assistant = capturedMessages[1] else {
            Issue.record("Expected assistant message second")
            return
        }
        guard case let .user(followUp) = capturedMessages[2] else {
            Issue.record("Expected user message third")
            return
        }
        #expect(followUp == "Follow-up")
    }

    @Test
    func resultContainsHistory() async throws {
        let finishCall = ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let result = try await agent.run(userMessage: "Test", context: EmptyContext())

        #expect(result.history.count == 2)
        guard case .user = result.history[0] else {
            Issue.record("Expected user message first in history")
            return
        }
        guard case .assistant = result.history[1] else {
            Issue.record("Expected assistant message second in history")
            return
        }
    }

    @Test
    func historyWithSystemPromptOrdering() async throws {
        let client = CapturingMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
            ])]
        )
        let config = AgentConfiguration(systemPrompt: "You are helpful.")
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        let history: [ChatMessage] = [
            .user("Previous question"),
            .assistant(AssistantMessage(content: "Previous answer"))
        ]
        _ = try await agent.run(userMessage: "Follow-up", history: history, context: EmptyContext())

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 4)

        guard case let .system(prompt) = capturedMessages[0] else {
            Issue.record("Expected system message first")
            return
        }
        #expect(prompt == "You are helpful.")

        guard case let .user(histUser) = capturedMessages[1] else {
            Issue.record("Expected history user message second")
            return
        }
        #expect(histUser == "Previous question")

        guard case let .assistant(histAssistant) = capturedMessages[2] else {
            Issue.record("Expected history assistant message third")
            return
        }
        #expect(histAssistant.content == "Previous answer")

        guard case let .user(newUser) = capturedMessages[3] else {
            Issue.record("Expected new user message fourth")
            return
        }
        #expect(newUser == "Follow-up")
    }

    @Test
    func multiTurnConversationHistoryAccumulates() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let toolCall = ToolCall(id: "call_1", name: "echo", arguments: #"{"message": "hello"}"#)
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "done"}"#)

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "Calling echo", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])
        let result = try await agent.run(userMessage: "Test", context: EmptyContext())

        #expect(result.history.count == 4)

        guard case .user = result.history[0] else {
            Issue.record("Expected user message first in history")
            return
        }
        guard case let .assistant(first) = result.history[1] else {
            Issue.record("Expected first assistant message second")
            return
        }
        #expect(first.content == "Calling echo")
        #expect(first.toolCalls.count == 1)

        guard case let .tool(id, name, content) = result.history[2] else {
            Issue.record("Expected tool result third")
            return
        }
        #expect(id == "call_1")
        #expect(name == "echo")
        #expect(content.contains("Echo: hello"))

        guard case .assistant = result.history[3] else {
            Issue.record("Expected final assistant message fourth")
            return
        }
    }

    @Test
    func historyFromPreviousRunCanBeChained() async throws {
        let finishCall = ToolCall(id: "1", name: "finish", arguments: #"{"content": "response 1"}"#)
        let client1 = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent1 = Agent<EmptyContext>(client: client1, tools: [])
        let result1 = try await agent1.run(userMessage: "First message", context: EmptyContext())

        let finishCall2 = ToolCall(id: "2", name: "finish", arguments: #"{"content": "response 2"}"#)
        let client2 = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall2])
        ])
        let agent2 = Agent<EmptyContext>(client: client2, tools: [])
        let result2 = try await agent2.run(
            userMessage: "Second message",
            history: result1.history,
            context: EmptyContext()
        )

        let capturedMessages = await client2.capturedMessages
        #expect(capturedMessages.count == 3)

        guard case let .user(first) = capturedMessages[0] else {
            Issue.record("Expected first user message")
            return
        }
        #expect(first == "First message")

        guard case .assistant = capturedMessages[1] else {
            Issue.record("Expected assistant from first run")
            return
        }

        guard case let .user(second) = capturedMessages[2] else {
            Issue.record("Expected second user message")
            return
        }
        #expect(second == "Second message")

        #expect(result2.history.count == 4)
    }
}

@Suite
struct AgentTruncationTests {
    @Test
    func truncationPreservesSystemPrompt() async throws {
        let client = CapturingMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
            ])]
        )
        let config = AgentConfiguration(systemPrompt: "System", maxMessages: 2)
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        let history: [ChatMessage] = [
            .user("Old message 1"),
            .assistant(AssistantMessage(content: "Old response 1")),
            .user("Old message 2"),
            .assistant(AssistantMessage(content: "Old response 2"))
        ]
        _ = try await agent.run(userMessage: "New message", history: history, context: EmptyContext())

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 3)
        guard case let .system(prompt) = capturedMessages[0] else {
            Issue.record("Expected system message preserved")
            return
        }
        #expect(prompt == "System")
        guard case .assistant = capturedMessages[1] else {
            Issue.record("Expected recent assistant message")
            return
        }
        guard case let .user(msg) = capturedMessages[2] else {
            Issue.record("Expected new user message")
            return
        }
        #expect(msg == "New message")
    }

    @Test
    func truncationAppliedBeforeEachLLMCall() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let toolCall = ToolCall(id: "call_1", name: "echo", arguments: #"{"message": "hello"}"#)
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "done"}"#)

        let client = AllCallsCapturingMockLLMClient(responses: [
            AssistantMessage(content: "First", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let config = AgentConfiguration(systemPrompt: "System", maxMessages: 3)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        _ = try await agent.run(userMessage: "Start", context: EmptyContext())

        let allCalls = await client.allCapturedMessages
        #expect(allCalls.count == 2)

        let firstCall = allCalls[0]
        #expect(firstCall.count == 2)

        let secondCall = allCalls[1]
        #expect(secondCall.count == 4)
        guard case .system = secondCall[0] else {
            Issue.record("Expected system message preserved in second call")
            return
        }
    }

    @Test
    func truncationPreservesToolCallResultPairsDuringAgentLoop() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let toolCall1 = ToolCall(id: "call_1", name: "echo", arguments: #"{"message": "first"}"#)
        let toolCall2 = ToolCall(id: "call_2", name: "echo", arguments: #"{"message": "second"}"#)
        let finishCall = ToolCall(id: "call_3", name: "finish", arguments: #"{"content": "done"}"#)

        let client = AllCallsCapturingMockLLMClient(responses: [
            AssistantMessage(content: "First tool", toolCalls: [toolCall1]),
            AssistantMessage(content: "Second tool", toolCalls: [toolCall2]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let config = AgentConfiguration(systemPrompt: "System", maxMessages: 4)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        _ = try await agent.run(userMessage: "Start", context: EmptyContext())

        let allCalls = await client.allCapturedMessages
        #expect(allCalls.count == 3)

        let thirdCall = allCalls[2]
        var hasToolCall = false
        var hasToolResult = false
        for message in thirdCall {
            if case let .assistant(assistant) = message, !assistant.toolCalls.isEmpty {
                hasToolCall = true
            }
            if case .tool = message {
                hasToolResult = true
            }
        }
        #expect(hasToolCall, "Expected at least one tool call in truncated messages")
        #expect(hasToolResult, "Expected at least one tool result in truncated messages")
    }

    @Test
    func multiTurnTruncationMaintainsValidConversation() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let toolCall = ToolCall(id: "call_1", name: "echo", arguments: #"{"message": "test"}"#)
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "done"}"#)

        let client = AllCallsCapturingMockLLMClient(responses: [
            AssistantMessage(content: "Calling tool", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let config = AgentConfiguration(systemPrompt: "System", maxMessages: 3)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        _ = try await agent.run(userMessage: "Start", context: EmptyContext())

        let allCalls = await client.allCapturedMessages
        let secondCall = allCalls[1]

        var toolCallIDs = Set<String>()
        var toolResultIDs = Set<String>()
        for message in secondCall {
            if case let .assistant(assistant) = message {
                for call in assistant.toolCalls {
                    toolCallIDs.insert(call.id)
                }
            }
            if case let .tool(id, _, _) = message {
                toolResultIDs.insert(id)
            }
        }
        #expect(!toolCallIDs.isEmpty, "Expected tool calls in conversation")
        #expect(!toolResultIDs.isEmpty, "Expected tool results in conversation")
        #expect(toolResultIDs.isSubset(of: toolCallIDs), "Tool results must have matching tool calls")
    }
}

private struct EchoParams: Codable, SchemaProviding, Sendable {
    let message: String
    static var jsonSchema: JSONSchema { .object(properties: ["message": .string()], required: ["message"]) }
}

private struct EchoOutput: Codable, Sendable {
    let echoed: String
}

private actor AllCallsCapturingMockLLMClient: LLMClient {
    private let responses: [AssistantMessage]
    private var callIndex: Int = 0
    private(set) var allCapturedMessages: [[ChatMessage]] = []

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        allCapturedMessages.append(messages)
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
