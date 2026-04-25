@testable import AgentRunKit
import Foundation
import Testing

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

struct ChatTimeoutTests {
    @Test
    func chatHonorsPerToolTimeoutOverride() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            toolTimeout: .milliseconds(50),
            executor: { _, _ in
                try await Task.sleep(for: .seconds(10))
                return NoopOutput()
            }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "slow", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("recovered"),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [slowTool], toolTimeout: .seconds(30))

        var events: [StreamEvent] = []
        for try await event in chat.stream("Run slow", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, name, result) = event.kind {
                return name == "slow" && result.isError && result.content.contains("timed out")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }

    @Test
    func chatHonorsSubAgentToolTimeoutOverride() async throws {
        let delayTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "delay",
            description: "Delays",
            executor: { _, _ in
                try await Task.sleep(for: .seconds(10))
                return NoopOutput()
            }
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [ToolCall(id: "c0", name: "delay", arguments: "{}")]),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "c1", name: "finish", arguments: #"{"content": "child done"}"#)]
            ),
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [delayTool])

        let slowSub = try SubAgentTool<EchoParams, EmptyContext>(
            name: "slow_sub",
            description: "Slow sub-agent",
            agent: childAgent,
            toolTimeout: .milliseconds(50),
            messageBuilder: { $0.message }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "sub_call", name: "slow_sub", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"hi"}"#),
            .finished(usage: nil),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("recovered"),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<SubAgentContext<EmptyContext>>(
            client: client, tools: [slowSub], toolTimeout: .seconds(30)
        )

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in chat.stream("Go", context: ctx) {
            events.append(event)
        }

        let timedOut = events.contains { event in
            if case let .toolCallCompleted(_, name, result) = event.kind {
                return name == "slow_sub" && result.isError && result.content.contains("timed out")
            }
            return false
        }
        #expect(timedOut)
    }

    @Test
    func chatToolTimeoutNilInheritsChatDefault() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            toolTimeout: nil,
            executor: { _, _ in
                try await Task.sleep(for: .milliseconds(500))
                return NoopOutput()
            }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "slow", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("recovered"),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [slowTool], toolTimeout: .milliseconds(50))

        var events: [StreamEvent] = []
        for try await event in chat.stream("Run slow", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, name, result) = event.kind {
                return name == "slow" && result.isError && result.content.contains("timed out")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }
}
