@testable import AgentRunKit
import Foundation
import Testing

private struct QueryParams: Codable, SchemaProviding {
    let query: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}

struct SubAgentStreamingLifecycleTests {
    @Test
    func emitsLifecycleEvents() async throws {
        let childDeltas: [StreamDelta] = [
            .content("child thinking..."),
            .toolCallStart(index: 0, id: "child_finish", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "child result"}"#),
            .finished(usage: nil),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_sub", name: "research"),
            .toolCallDelta(index: 0, arguments: #"{"query": "test"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_finish", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "parent done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            events.append(event)
        }

        let started = events.contains { event in
            if case let .subAgentStarted(id, name) = event.kind {
                return id == "call_sub" && name == "research"
            }
            return false
        }
        #expect(started)

        let hasChildDelta = events.contains { event in
            if case let .subAgentEvent(id, name, inner) = event.kind {
                if case .delta("child thinking...") = inner.kind {
                    return id == "call_sub" && name == "research"
                }
            }
            return false
        }
        #expect(hasChildDelta)

        let completed = events.contains { event in
            if case let .subAgentCompleted(id, name, result) = event.kind {
                return id == "call_sub" && name == "research"
                    && result.content == "child result" && !result.isError
            }
            return false
        }
        #expect(completed)

        let toolCompleted = events.contains { event in
            if case let .toolCallCompleted(id, name, result) = event.kind {
                return id == "call_sub" && name == "research"
                    && result.content == "child result" && !result.isError
            }
            return false
        }
        #expect(toolCompleted)

        let startedIdx = events.firstIndex { if case .subAgentStarted = $0.kind { return true }; return false }
        let completedIdx = events.firstIndex { if case .subAgentCompleted = $0.kind { return true }; return false }
        let toolCompletedIdx = events.firstIndex { if case .toolCallCompleted = $0.kind { return true }; return false }
        #expect(try #require(startedIdx) < #require(completedIdx))
        #expect(try #require(completedIdx) < #require(toolCompletedIdx))
    }

    @Test
    func emittedEventsCarryStage1EnvelopeMetadata() async throws {
        let childDeltas: [StreamDelta] = [
            .content("child thinking..."),
            .toolCallStart(index: 0, id: "child_finish", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "child result"}"#),
            .finished(usage: nil),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_sub", name: "research"),
            .toolCallDelta(index: 0, arguments: #"{"query": "test"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_finish", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "parent done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let startedAt = Date()
        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            events.append(event)
        }
        let endedAt = Date()

        #expect(events.contains {
            if case .subAgentEvent = $0.kind { return true }
            return false
        })
        StreamEventInvariantAssertions.assertStage1RuntimeInvariants(
            events,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    @Test
    func identityInEvents() async throws {
        let childDeltas: [StreamDelta] = [
            .content("working"),
            .toolCallStart(index: 0, id: "cf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "analyzer",
            description: "Analyzer tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_xyz", name: "analyzer"),
            .toolCallDelta(index: 0, arguments: #"{"query": "analyze this"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "all done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        var subAgentEvents: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            switch event.kind {
            case .subAgentStarted, .subAgentEvent, .subAgentCompleted:
                subAgentEvents.append(event)
            default:
                break
            }
        }

        #expect(subAgentEvents.count >= 3)
        for event in subAgentEvents {
            switch event.kind {
            case let .subAgentStarted(id, name):
                #expect(id == "call_xyz")
                #expect(name == "analyzer")
            case let .subAgentEvent(id, name, _):
                #expect(id == "call_xyz")
                #expect(name == "analyzer")
            case let .subAgentCompleted(id, name, _):
                #expect(id == "call_xyz")
                #expect(name == "analyzer")
            default:
                Issue.record("Unexpected event type")
            }
        }
    }

    @Test
    func noDoubleReportingOnError() async throws {
        let childClient = StreamingMockLLMClient(streamSequences: [])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "failing",
            description: "Fails",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_fail", name: "failing"),
            .toolCallDelta(index: 0, arguments: #"{"query": "boom"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "ok"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            events.append(event)
        }

        let completedCount = events.count(where: { event in
            if case let .subAgentCompleted(_, _, result) = event.kind { return result.isError }
            return false
        })
        #expect(completedCount == 1)

        let toolCompletedCount = events.count(where: { event in
            if case let .toolCallCompleted(_, name, _) = event.kind {
                return name == "failing"
            }
            return false
        })
        #expect(toolCompletedCount == 1)
    }
}

struct SubAgentSystemPromptTests {
    @Test
    func overrideUsedInStreaming() async throws {
        let childDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "child done"}"#),
            .finished(usage: nil),
        ]
        let childClient = CapturingStreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient, tools: [],
            configuration: AgentConfiguration(systemPrompt: "default prompt")
        )

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: childAgent,
            systemPromptBuilder: { "You are researching: \($0.query)" },
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_sub", name: "research"),
            .toolCallDelta(index: 0, arguments: #"{"query": "climate change"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await _ in parentAgent.stream(userMessage: "Go", context: ctx) {}

        let captured = await childClient.capturedMessages
        guard case let .system(prompt) = captured.first else {
            Issue.record("Expected system message from child agent")
            return
        }
        #expect(prompt == "You are researching: climate change")
    }

    @Test
    func overrideUsedInNonStreaming() async throws {
        let finishCall = ToolCall(
            id: "cf", name: "finish",
            arguments: #"{"content": "child done"}"#
        )
        let childClient = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient, tools: [],
            configuration: AgentConfiguration(systemPrompt: "default prompt")
        )

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: childAgent,
            systemPromptBuilder: { "Override: \($0.query)" },
            messageBuilder: { $0.query }
        )

        let subCall = ToolCall(id: "cs", name: "research", arguments: #"{"query": "test"}"#)
        let parentFinish = ToolCall(id: "pf", name: "finish", arguments: #"{"content": "parent done"}"#)
        let parentClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [subCall]),
            AssistantMessage(content: "", toolCalls: [parentFinish]),
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await parentAgent.run(userMessage: "Go", context: ctx)
        #expect(try requireContent(result) == "parent done")

        let captured = await childClient.capturedMessages
        guard case let .system(prompt) = captured.first else {
            Issue.record("Expected system message from child agent")
            return
        }
        #expect(prompt == "Override: test")
    }
}

struct SubAgentTimeoutTests {
    @Test
    func errorYieldsCompletedWithErrorResult() async throws {
        let childClient = StreamingMockLLMClient(streamSequences: [])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "failing",
            description: "Fails",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_fail", name: "failing"),
            .toolCallDelta(index: 0, arguments: #"{"query": "boom"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "recovered"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            events.append(event)
        }

        let completedEvents = events.filter { event in
            if case let .subAgentCompleted(_, _, result) = event.kind {
                return result.isError
            }
            return false
        }
        #expect(completedEvents.count == 1)

        guard case let .finished(_, content, _, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "recovered")
    }

    @Test
    func nilTimeoutMeansNoTimeout() async throws {
        let childClient = ControllableStreamingMockLLMClient()
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            agent: childAgent,
            toolTimeout: nil,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_slow", name: "slow"),
            .toolCallDelta(index: 0, arguments: #"{"query": "think hard"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let config = AgentConfiguration(toolTimeout: .milliseconds(50))
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool], configuration: config
        )

        await childClient.setStreamStartedHandler {
            Task {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                await childClient.yieldDelta(.toolCallStart(index: 0, id: "cf", name: "finish"))
                await childClient.yieldDelta(.toolCallDelta(index: 0, arguments: #"{"content": "slow result"}"#))
                await childClient.yieldDelta(.finished(usage: nil))
                await childClient.finishStream()
            }
        }

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            events.append(event)
        }

        let completed = events.contains { event in
            if case let .subAgentCompleted(_, _, result) = event.kind {
                return result.content == "slow result" && !result.isError
            }
            return false
        }
        #expect(completed)
    }

    @Test
    func timeoutOverrideRespected() async throws {
        let childClient = ControllableStreamingMockLLMClient()
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            agent: childAgent,
            toolTimeout: .milliseconds(50),
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_slow", name: "slow"),
            .toolCallDelta(index: 0, arguments: #"{"query": "think"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "recovered"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let config = AgentConfiguration(toolTimeout: .seconds(30))
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool], configuration: config
        )

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            events.append(event)
        }

        let timedOut = events.contains { event in
            if case let .subAgentCompleted(_, _, result) = event.kind {
                return result.isError && result.content.contains("timed out")
            }
            return false
        }
        #expect(timedOut)
    }
}

struct SubAgentNestingTests {
    @Test
    func nestedSubAgentsStreamRecursively() async throws {
        let innerDeltas: [StreamDelta] = [
            .content("inner working"),
            .toolCallStart(index: 0, id: "inner_f", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "inner result"}"#),
            .finished(usage: nil),
        ]
        let innerClient = StreamingMockLLMClient(streamSequences: [innerDeltas])
        let innerAgent = Agent<SubAgentContext<EmptyContext>>(client: innerClient, tools: [])

        let innerTool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "inner",
            description: "Inner sub-agent",
            agent: innerAgent,
            messageBuilder: { $0.query }
        )

        let outerDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_inner", name: "inner"),
            .toolCallDelta(index: 0, arguments: #"{"query": "go deeper"}"#),
            .finished(usage: nil),
        ]
        let outerDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "outer_f", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "outer result"}"#),
            .finished(usage: nil),
        ]
        let outerClient = StreamingMockLLMClient(streamSequences: [outerDeltas1, outerDeltas2])
        let outerAgent = Agent<SubAgentContext<EmptyContext>>(client: outerClient, tools: [innerTool])

        let outerTool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "outer",
            description: "Outer sub-agent",
            agent: outerAgent,
            messageBuilder: { $0.query }
        )

        let rootDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_outer", name: "outer"),
            .toolCallDelta(index: 0, arguments: #"{"query": "start"}"#),
            .finished(usage: nil),
        ]
        let rootDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "root_f", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "root done"}"#),
            .finished(usage: nil),
        ]
        let rootClient = StreamingMockLLMClient(streamSequences: [rootDeltas1, rootDeltas2])
        let rootAgent = Agent<SubAgentContext<EmptyContext>>(client: rootClient, tools: [outerTool])

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 4)
        for try await event in rootAgent.stream(userMessage: "Go", context: ctx) {
            events.append(event)
        }

        let outerStarted = events.contains { event in
            if case let .subAgentStarted(_, name) = event.kind { return name == "outer" }
            return false
        }
        #expect(outerStarted)

        let innerNestedInOuter = events.contains { event in
            if case let .subAgentEvent(_, outerName, innerEvent) = event.kind, outerName == "outer" {
                if case let .subAgentEvent(_, innerName, deepEvent) = innerEvent.kind, innerName == "inner" {
                    if case .delta("inner working") = deepEvent.kind { return true }
                }
            }
            return false
        }
        #expect(innerNestedInOuter)

        guard case let .finished(_, content, _, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "root done")
    }
}

struct SubAgentApprovalStreamingTests {
    @Test
    func childApprovalEventsPropagateWhenParentPolicyIsNone() async throws {
        let childNoopTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "child_noop",
            description: "Child no-op",
            executor: { _, _ in NoopOutput() }
        )
        let childDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_tool", name: "child_noop"),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: nil),
        ]
        let childDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_finish", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content":"child done"}"#),
            .finished(usage: nil),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas1, childDeltas2])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient,
            tools: [childNoopTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "delegate",
            description: "Delegates work",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "parent_tool", name: "delegate"),
            .toolCallDelta(index: 0, arguments: #"{"query":"go"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "parent_finish", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content":"parent done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])
        let counter = CountingApprovalHandler()

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in parentAgent.stream(
            userMessage: "Go",
            context: ctx,
            approvalHandler: counter.handler
        ) {
            events.append(event)
        }

        let requests = await counter.requests
        #expect(requests.map(\.toolName) == ["child_noop"])

        let nestedApprovalRequested = containsNestedApprovalRequested(events, toolName: "delegate")
        #expect(nestedApprovalRequested)

        let nestedApprovalResolved = containsNestedApprovalResolved(events, toolName: "delegate")
        #expect(nestedApprovalResolved)

        let toolCompleted = containsCompletedToolCall(
            events,
            id: "parent_tool",
            name: "delegate",
            content: "child done"
        )
        #expect(toolCompleted)
    }
}

private func containsNestedApprovalRequested(_ events: [StreamEvent], toolName: String) -> Bool {
    events.contains { event in
        if case let .subAgentEvent(_, innerToolName, innerEvent) = event.kind,
           innerToolName == toolName,
           case .toolApprovalRequested = innerEvent.kind {
            return true
        }
        return false
    }
}

private func containsNestedApprovalResolved(_ events: [StreamEvent], toolName: String) -> Bool {
    events.contains { event in
        if case let .subAgentEvent(_, innerToolName, innerEvent) = event.kind,
           innerToolName == toolName,
           case .toolApprovalResolved = innerEvent.kind {
            return true
        }
        return false
    }
}

private func containsCompletedToolCall(
    _ events: [StreamEvent],
    id: String,
    name: String,
    content: String
) -> Bool {
    events.contains { event in
        if case let .toolCallCompleted(eventId, eventName, result) = event.kind {
            return eventId == id && eventName == name && result.content == content && !result.isError
        }
        return false
    }
}

private struct BlockingStreamableTool: AnyTool, StreamableSubAgentTool {
    typealias Context = SubAgentContext<EmptyContext>

    let name = "blocking"
    let description = "Blocks until cancelled"
    let parametersSchema: JSONSchema = .object(properties: ["query": .string()], required: ["query"])

    func execute(arguments _: Data, context _: Context) async throws -> ToolResult {
        try await Task.sleep(for: .seconds(60))
        return .error("Should not reach here")
    }

    func executeStreaming(
        toolCallId _: String,
        arguments _: Data,
        context _: Context,
        eventHandler _: @Sendable (StreamEvent) -> Void
    ) async throws -> ToolResult {
        try await Task.sleep(for: .seconds(60))
        return .error("Should not reach here")
    }
}

struct SubAgentCancellationTests {
    @Test
    func cancellationDuringSubAgentTerminatesStream() async throws {
        let tool = BlockingStreamableTool()

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_block", name: "blocking"),
            .toolCallDelta(index: 0, arguments: #"{"query": "wait"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let stream = parentAgent.stream(userMessage: "Go", context: ctx)

        let collector = StreamingEventCollector()
        let task = Task {
            for try await event in stream {
                await collector.append(event)
            }
        }

        for _ in 0 ..< 50 {
            let started = await collector.events.contains { event in
                if case .subAgentStarted = event.kind { return true }
                return false
            }
            if started { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        task.cancel()
        try? await task.value

        let events = await collector.events
        let hasNoFinished = !events.contains { event in
            if case .finished = event.kind { return true }
            return false
        }
        #expect(hasNoFinished)

        let hasStarted = events.contains { event in
            if case let .subAgentStarted(id, name) = event.kind {
                return id == "call_block" && name == "blocking"
            }
            return false
        }
        #expect(hasStarted)
    }
}

struct SubAgentDepthLimitStreamingTests {
    @Test
    func executeStreamingThrowsAtMaxDepth() async throws {
        let childClient = StreamingMockLLMClient(streamSequences: [])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "deep",
            description: "Deep tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let args = try JSONEncoder().encode(QueryParams(query: "test"))
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 2, currentDepth: 2)

        do {
            _ = try await tool.executeStreaming(
                toolCallId: "call_deep", arguments: args,
                context: ctx, eventHandler: { _ in }
            )
            Issue.record("Expected maxDepthExceeded")
        } catch let error as AgentError {
            guard case let .maxDepthExceeded(depth) = error else {
                Issue.record("Expected maxDepthExceeded, got \(error)")
                return
            }
            #expect(depth == 2)
        }
    }
}

struct SubAgentInheritHistoryStreamingTests {
    @Test
    func childSeesParentHistoryInStreaming() async throws {
        let childDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "child done"}"#),
            .finished(usage: nil),
        ]
        let childClient = CapturingStreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient, tools: [],
            configuration: AgentConfiguration(systemPrompt: "child system")
        )
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: childAgent,
            inheritParentMessages: true,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cs", name: "research"),
            .toolCallDelta(index: 0, arguments: #"{"query": "task"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "parent done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool],
            configuration: AgentConfiguration(systemPrompt: "parent system")
        )

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await _ in parentAgent.stream(userMessage: "Go", context: ctx) {}

        let captured = await childClient.capturedMessages
        #expect(captured.count == 3)
        guard case let .system(prompt) = captured[0] else {
            Issue.record("Expected child system message first")
            return
        }
        #expect(prompt == "child system")
        guard case let .user(userMsg) = captured[1] else {
            Issue.record("Expected parent user message")
            return
        }
        #expect(userMsg == "Go")
        guard case let .user(taskMsg) = captured[2] else {
            Issue.record("Expected child task message last")
            return
        }
        #expect(taskMsg == "task")
    }

    @Test
    func parallelSiblingsInheritSameHistory() async throws {
        let child1Deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cf1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "child1 done"}"#),
            .finished(usage: nil),
        ]
        let child1Client = CapturingStreamingMockLLMClient(streamSequences: [child1Deltas])
        let child1Agent = Agent<SubAgentContext<EmptyContext>>(
            client: child1Client, tools: [],
            configuration: AgentConfiguration(systemPrompt: "child1 system")
        )
        let tool1 = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research1",
            description: "Research 1",
            agent: child1Agent,
            inheritParentMessages: true,
            messageBuilder: { $0.query }
        )

        let child2Deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cf2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "child2 done"}"#),
            .finished(usage: nil),
        ]
        let child2Client = CapturingStreamingMockLLMClient(streamSequences: [child2Deltas])
        let child2Agent = Agent<SubAgentContext<EmptyContext>>(
            client: child2Client, tools: [],
            configuration: AgentConfiguration(systemPrompt: "child2 system")
        )
        let tool2 = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research2",
            description: "Research 2",
            agent: child2Agent,
            inheritParentMessages: true,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cs1", name: "research1"),
            .toolCallDelta(index: 0, arguments: #"{"query": "task1"}"#),
            .toolCallStart(index: 1, id: "cs2", name: "research2"),
            .toolCallDelta(index: 1, arguments: #"{"query": "task2"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "parent done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool1, tool2],
            configuration: AgentConfiguration(systemPrompt: "parent system")
        )

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await _ in parentAgent.stream(userMessage: "Go", context: ctx) {}

        let captured1 = await child1Client.capturedMessages
        let captured2 = await child2Client.capturedMessages

        let history1 = captured1.dropFirst().dropLast()
        let history2 = captured2.dropFirst().dropLast()
        #expect(Array(history1) == Array(history2))

        let systemMessages1 = captured1.filter(\.isSystem)
        let systemMessages2 = captured2.filter(\.isSystem)
        #expect(systemMessages1.count == 1)
        #expect(systemMessages2.count == 1)
    }

    @Test
    func childInheritsAssistantContinuityFromParentHistory() async throws {
        let continuity = AssistantContinuity(
            substrate: .responses,
            payload: .object([
                "response_id": .string("resp_parent"),
            ])
        )
        let childDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "child done"}"#),
            .finished(usage: nil),
        ]
        let childClient = CapturingStreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient, tools: [],
            configuration: AgentConfiguration(systemPrompt: "child system")
        )
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: childAgent,
            inheritParentMessages: true,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cs", name: "research"),
            .toolCallDelta(index: 0, arguments: #"{"query": "task"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "parent done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool],
            configuration: AgentConfiguration(systemPrompt: "parent system")
        )
        let history: [ChatMessage] = [
            .user("Earlier"),
            .assistant(AssistantMessage(content: "Earlier answer", continuity: continuity)),
        ]

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await _ in parentAgent.stream(userMessage: "Go", history: history, context: ctx) {}

        let captured = await childClient.capturedMessages
        #expect(captured.count == 5)
        guard case let .assistant(message) = captured[2] else {
            Issue.record("Expected inherited assistant message in child history")
            return
        }
        #expect(message.content == "Earlier answer")
        #expect(message.continuity == continuity)
    }
}
