import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct AgentErrorTests {
    @Test
    func toolNotFoundFeedsErrorToLLM() async throws {
        let toolCall = ToolCall(id: "call_1", name: "nonexistent", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "recovered"}"#)
        let client = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let result = try await agent.run(userMessage: "Unknown", context: EmptyContext())
        #expect(result.content == "recovered")

        let capturedMessages = await client.capturedMessages
        let toolMessage = capturedMessages.compactMap { msg -> (String, String)? in
            guard case let .tool(_, name, content) = msg else { return nil }
            return (name, content)
        }.last
        #expect(toolMessage?.0 == "nonexistent")
        #expect(toolMessage?.1.contains("does not exist") == true)
    }

    @Test
    func finishDecodingFailed() async throws {
        let finishCall = ToolCall(id: "call_1", name: "finish", arguments: "invalid json")
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            _ = try await agent.run(userMessage: "Bad finish", context: EmptyContext())
            Issue.record("Expected finishDecodingFailed error")
        } catch let error as AgentError {
            guard case .finishDecodingFailed = error else {
                Issue.record("Expected finishDecodingFailed, got \(error)")
                return
            }
        }
    }

    @Test
    func toolExecutionErrorFeedsToLLM() async throws {
        let failingTool = Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "failing",
            description: "Always fails",
            executor: { _, _ in throw AgentErrorTestError.intentional }
        )
        let toolCall = ToolCall(id: "call_1", name: "failing", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "recovered"}"#)
        let client = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [failingTool])

        let result = try await agent.run(userMessage: "Fail", context: EmptyContext())
        #expect(result.content == "recovered")

        let capturedMessages = await client.capturedMessages
        let toolMessage = capturedMessages.compactMap { msg -> (String, String)? in
            guard case let .tool(_, name, content) = msg else { return nil }
            return (name, content)
        }.last
        #expect(toolMessage?.0 == "failing")
        #expect(toolMessage?.1.contains("failed") == true)
    }

    @Test
    func toolDecodingFailedFeedsErrorToLLM() async throws {
        let echoTool = Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let toolCall = ToolCall(id: "call_1", name: "echo", arguments: "not valid json")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "recovered"}"#)
        let client = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        let result = try await agent.run(userMessage: "Bad args", context: EmptyContext())
        #expect(result.content == "recovered")

        let capturedMessages = await client.capturedMessages
        let toolMessage = capturedMessages.compactMap { msg -> (String, String)? in
            guard case let .tool(_, name, content) = msg else { return nil }
            return (name, content)
        }.last
        #expect(toolMessage?.0 == "echo")
        #expect(toolMessage?.1.contains("Invalid arguments") == true)
    }

    @Test
    func llmErrorPropagates() async throws {
        let client = FailingMockLLMClient()
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            _ = try await agent.run(userMessage: "Fail", context: EmptyContext())
            Issue.record("Expected llmError")
        } catch let error as AgentError {
            guard case .llmError = error else {
                Issue.record("Expected llmError, got \(error)")
                return
            }
        }
    }

    @Test
    func feedbackMessageContainsRelevantInfo() {
        let error1 = AgentError.toolNotFound(name: "myTool")
        #expect(error1.feedbackMessage.contains("myTool"))
        #expect(error1.feedbackMessage.contains("Error"))

        let error2 = AgentError.toolDecodingFailed(tool: "parser", message: "missing field")
        #expect(error2.feedbackMessage.contains("parser"))
        #expect(error2.feedbackMessage.contains("missing field"))

        let error3 = AgentError.toolTimeout(tool: "slowTool")
        #expect(error3.feedbackMessage.contains("slowTool"))
        #expect(error3.feedbackMessage.contains("timed out"))

        let error4 = AgentError.toolExecutionFailed(tool: "crasher", message: "null pointer")
        #expect(error4.feedbackMessage.contains("crasher"))
        #expect(error4.feedbackMessage.contains("null pointer"))

        let error5 = AgentError.toolEncodingFailed(tool: "encoder", message: "invalid utf8")
        #expect(error5.feedbackMessage.contains("encoder"))
        #expect(error5.feedbackMessage.contains("invalid utf8"))

        let error6 = AgentError.maxIterationsReached(iterations: 10)
        #expect(error6.feedbackMessage.contains("10"))
        #expect(error6.feedbackMessage.contains("iterations"))

        let error7 = AgentError.finishDecodingFailed(message: "unexpected token")
        #expect(error7.feedbackMessage.contains("unexpected token"))

        let error8 = AgentError.llmError(.other("rate limited"))
        #expect(error8.feedbackMessage.contains("rate limited"))

        let error9 = AgentError.malformedStream(.toolCallDeltaWithoutStart(index: 3))
        #expect(error9.feedbackMessage.contains("3"))

        let error10 = AgentError.malformedStream(.missingToolCallId(index: 5))
        #expect(error10.feedbackMessage.contains("5"))
        #expect(error10.feedbackMessage.contains("ID"))

        let error11 = AgentError.malformedStream(.missingToolCallName(index: 7))
        #expect(error11.feedbackMessage.contains("7"))
        #expect(error11.feedbackMessage.contains("name"))
    }
}

private struct EchoParams: Codable, SchemaProviding, Sendable {
    let message: String
    static var jsonSchema: JSONSchema { .object(properties: ["message": .string()], required: ["message"]) }
}

private struct EchoOutput: Codable, Sendable {
    let echoed: String
}

private struct NoopParams: Codable, SchemaProviding, Sendable {
    static var jsonSchema: JSONSchema { .object(properties: [:], required: []) }
}

private struct NoopOutput: Codable, Sendable {}

private enum AgentErrorTestError: Error, Sendable {
    case intentional
}

actor FailingMockLLMClient: LLMClient {
    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        throw AgentError.llmError(.other("Intentional test failure"))
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream {
            $0.finish(throwing: AgentError.llmError(.other("Intentional test failure")))
        }
    }
}
