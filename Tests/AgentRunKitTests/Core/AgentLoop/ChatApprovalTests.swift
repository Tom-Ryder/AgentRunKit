@testable import AgentRunKit
import Foundation
import Testing

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}

struct ChatApprovalTests {
    @Test
    func unknownToolSkipsApprovalHandler() async throws {
        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "nonexistent", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: nil),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("Recovered"),
            .finished(usage: nil),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, approvalPolicy: .allTools)
        let counter = CountingApprovalHandler()

        var events: [StreamEvent] = []
        for try await event in chat.stream(
            "Run nonexistent",
            context: EmptyContext(),
            approvalHandler: counter.handler
        ) {
            events.append(event)
        }

        let count = await counter.requestCount
        #expect(count == 0)

        let requestedApproval = events.contains { event in
            if case .toolApprovalRequested = event.kind { return true }
            return false
        }
        #expect(!requestedApproval)

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, _, result) = event.kind {
                return result.isError && result.content.contains("does not exist")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }

    @Test
    func subAgentToolForwardsApprovalHandler() async throws {
        let childNoopTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "child_noop",
            description: "Child no-op",
            executor: { _, _ in NoopOutput() }
        )
        let childDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_tool", name: "child_noop", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: nil),
        ]
        let childDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"child done"}"#),
            .finished(usage: nil),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas1, childDeltas2])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient,
            tools: [childNoopTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let delegateTool = try SubAgentTool<EchoParams, EmptyContext>(
            name: "delegate",
            description: "Delegates work",
            agent: childAgent,
            messageBuilder: { $0.message }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "delegate_call", name: "delegate", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"research"}"#),
            .finished(usage: nil),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("done"),
            .finished(usage: nil),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<SubAgentContext<EmptyContext>>(
            client: client,
            tools: [delegateTool],
            approvalPolicy: .allTools
        )
        let counter = CountingApprovalHandler()

        var events: [StreamEvent] = []
        let context = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in chat.stream("Go", context: context, approvalHandler: counter.handler) {
            events.append(event)
        }

        let requests = await counter.requests
        #expect(requests.map(\.toolName) == ["delegate", "child_noop"])

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(id, name, result) = event.kind {
                return id == "delegate_call" && name == "delegate"
                    && result.content == "child done" && !result.isError
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }

    @Test
    func subAgentApprovalPropagatesWhenParentPolicyIsNone() async throws {
        let childNoopTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "child_noop",
            description: "Child no-op",
            executor: { _, _ in NoopOutput() }
        )
        let childDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_tool", name: "child_noop", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: nil),
        ]
        let childDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"child done"}"#),
            .finished(usage: nil),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas1, childDeltas2])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient,
            tools: [childNoopTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let delegateTool = try SubAgentTool<EchoParams, EmptyContext>(
            name: "delegate",
            description: "Delegates work",
            agent: childAgent,
            messageBuilder: { $0.message }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "delegate_call", name: "delegate", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"research"}"#),
            .finished(usage: nil),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("done"),
            .finished(usage: nil),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<SubAgentContext<EmptyContext>>(
            client: client,
            tools: [delegateTool],
            approvalPolicy: .none
        )
        let counter = CountingApprovalHandler()

        let context = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await _ in chat.stream("Go", context: context, approvalHandler: counter.handler) {}

        let requests = await counter.requests
        #expect(requests.count == 1)
        #expect(requests.first?.toolName == "child_noop")
    }

    @Test
    func modifiedArgumentsAreUsedForExecution() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes the message",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"original"}"#),
            .finished(usage: nil),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("done"),
            .finished(usage: nil),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [echoTool], approvalPolicy: .allTools)
        let counter = CountingApprovalHandler(
            decisions: ["echo": .approveWithModifiedArguments(#"{"message":"modified"}"#)]
        )

        var events: [StreamEvent] = []
        for try await event in chat.stream("Echo it", context: EmptyContext(), approvalHandler: counter.handler) {
            events.append(event)
        }

        let completedContent = events.compactMap { event -> String? in
            if case let .toolCallCompleted(id, _, result) = event.kind, id == "call_1", !result.isError {
                return result.content
            }
            return nil
        }.first
        let content = try #require(completedContent)
        #expect(content.contains("modified"))
        #expect(!content.contains("original"))
    }

    @Test
    func approveAlwaysSkipsHandlerForRepeatCallsInTheSameStream() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes the message",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallStart(index: 1, id: "call_2", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"first"}"#),
            .toolCallDelta(index: 1, arguments: #"{"message":"second"}"#),
            .finished(usage: nil),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("done"),
            .finished(usage: nil),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [echoTool], approvalPolicy: .allTools)
        let counter = CountingApprovalHandler(defaultDecision: .approveAlways)

        var events: [StreamEvent] = []
        for try await event in chat.stream("Echo twice", context: EmptyContext(), approvalHandler: counter.handler) {
            events.append(event)
        }

        let count = await counter.requestCount
        #expect(count == 1)

        let completedIds = events.compactMap { event -> String? in
            if case let .toolCallCompleted(id, _, result) = event.kind, !result.isError {
                return id
            }
            return nil
        }
        #expect(completedIds == ["call_1", "call_2"])
    }
}
