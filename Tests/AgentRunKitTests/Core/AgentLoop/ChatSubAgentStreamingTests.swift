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

private func toolCallTurn(id: String, name: String, arguments: String) -> [StreamDelta] {
    [
        .toolCallStart(index: 0, id: id, name: name, kind: .function),
        .toolCallDelta(index: 0, arguments: arguments),
        .finished(usage: nil),
    ]
}

private func contentTurn(_ content: String) -> [StreamDelta] {
    [.content(content), .finished(usage: nil)]
}

struct ChatSubAgentStreamingLifecycleTests {
    @Test
    func childEventsPropagateInLifecycleOrder() async throws {
        let childDeltas: [StreamDelta] = [
            .content("child thinking..."),
            .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
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

        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "call_sub", name: "research", arguments: #"{"query": "test"}"#),
            contentTurn("parent done"),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in chat.stream("Go", context: ctx) {
            events.append(event)
        }

        let startedIdx = events.firstIndex { event in
            if case let .subAgentStarted(id, name) = event.kind {
                return id == "call_sub" && name == "research"
            }
            return false
        }
        let childDeltaIdx = events.firstIndex { event in
            if case let .subAgentEvent(id, name, inner) = event.kind,
               case .delta("child thinking...") = inner.kind {
                return id == "call_sub" && name == "research"
            }
            return false
        }
        let completedIdx = events.firstIndex { event in
            if case let .subAgentCompleted(id, name, result) = event.kind {
                return id == "call_sub" && name == "research"
                    && result.content == "child result" && !result.isError
            }
            return false
        }
        let toolCompletedIdx = events.firstIndex { event in
            if case let .toolCallCompleted(id, name, result) = event.kind {
                return id == "call_sub" && name == "research"
                    && result.content == "child result" && !result.isError
            }
            return false
        }
        #expect(try #require(startedIdx) < #require(childDeltaIdx))
        #expect(try #require(childDeltaIdx) < #require(completedIdx))
        #expect(try #require(completedIdx) < #require(toolCompletedIdx))
    }

    @Test
    func outermostEventsCarryNilIdentityAndNestedEventsCarryChildSession() async throws {
        let childDeltas: [StreamDelta] = [
            .content("child thinking..."),
            .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
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

        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "call_sub", name: "research", arguments: #"{"query": "test"}"#),
            contentTurn("parent done"),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let startedAt = Date()
        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in chat.stream("Go", context: ctx) {
            events.append(event)
        }
        let endedAt = Date()

        #expect(events.contains { if case .subAgentStarted = $0.kind { return true }; return false })
        #expect(events.contains { if case .subAgentCompleted = $0.kind { return true }; return false })
        StreamEventInvariantAssertions.assertStage1RuntimeInvariants(
            events,
            startedAt: startedAt,
            endedAt: endedAt,
            scope: .chat
        )

        let nestedEvents = events.compactMap { event -> StreamEvent? in
            guard case let .subAgentEvent(_, _, nested) = event.kind else { return nil }
            return nested
        }
        #expect(!nestedEvents.isEmpty)
        #expect(nestedEvents.allSatisfy { $0.sessionID != nil })
        #expect(Set(nestedEvents.compactMap(\.sessionID)).count == 1)
    }

    @Test
    func nestedIterationCompletedCarriesChildHistory() async throws {
        let childDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "child result"}"#),
            .finished(usage: TokenUsage(input: 5, output: 3)),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "call_sub", name: "research", arguments: #"{"query": "test"}"#),
            contentTurn("parent done"),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in chat.stream("Go", context: ctx) {
            events.append(event)
        }

        let nestedHistories = events.compactMap { event -> [ChatMessage]? in
            guard case let .subAgentEvent(_, _, nested) = event.kind,
                  case let .iterationCompleted(_, _, history) = nested.kind else { return nil }
            return history
        }
        #expect(!nestedHistories.isEmpty)
        #expect(nestedHistories.allSatisfy { !$0.isEmpty })
    }
}

struct ChatSubAgentApprovalStreamingTests {
    @Test
    func childApprovalEventsPropagateWhenParentPolicyIsNone() async throws {
        let childNoopTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "child_noop",
            description: "Child no-op",
            executor: { _, _ in NoopOutput() }
        )
        let childClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "child_tool", name: "child_noop", arguments: "{}"),
            toolCallTurn(id: "child_finish", name: "finish", arguments: #"{"content":"child done"}"#),
        ])
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

        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "parent_tool", name: "delegate", arguments: #"{"query":"go"}"#),
            contentTurn("parent done"),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])
        let counter = CountingApprovalHandler()

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in chat.stream("Go", context: ctx, approvalHandler: counter.handler) {
            events.append(event)
        }

        let requests = await counter.requests
        #expect(requests.map(\.toolName) == ["child_noop"])
        #expect(containsNestedApprovalRequested(events, toolName: "delegate"))
        #expect(containsNestedApprovalResolved(events, toolName: "delegate"))

        let toolCompleted = events.contains { event in
            if case let .toolCallCompleted(id, name, result) = event.kind {
                return id == "parent_tool" && name == "delegate"
                    && result.content == "child done" && !result.isError
            }
            return false
        }
        #expect(toolCompleted)
    }

    @Test
    func deniedSubAgentEmitsOnlyToolCallCompleted() async throws {
        let childClient = StreamingMockLLMClient(streamSequences: [])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "delegate",
            description: "Delegates work",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "call_sub", name: "delegate", arguments: #"{"query":"go"}"#),
            contentTurn("parent done"),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool], approvalPolicy: .allTools
        )
        let counter = CountingApprovalHandler(decisions: ["delegate": .deny(reason: "not allowed")])

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in chat.stream("Go", context: ctx, approvalHandler: counter.handler) {
            events.append(event)
        }

        #expect(!events.contains { if case .subAgentStarted = $0.kind { return true }; return false })
        #expect(!events.contains { if case .subAgentEvent = $0.kind { return true }; return false })
        #expect(!events.contains { if case .subAgentCompleted = $0.kind { return true }; return false })

        let deniedResult = events.contains { event in
            if case let .toolCallCompleted(id, name, result) = event.kind {
                return id == "call_sub" && name == "delegate"
                    && result.isError && result.content == "not allowed"
            }
            return false
        }
        #expect(deniedResult)
    }
}

struct ChatSubAgentFailureTests {
    @Test
    func slowChildTimesOutInBothCompletionEventsAndStreamContinues() async throws {
        let childClient = ControllableStreamingMockLLMClient()
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "call_slow", name: "slow", arguments: #"{"query": "think"}"#),
            contentTurn("recovered"),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool], toolTimeout: .milliseconds(50)
        )

        await childClient.setStreamStartedHandler {
            Task {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                await childClient.yieldDelta(.toolCallStart(index: 0, id: "cf", name: "finish", kind: .function))
                await childClient.yieldDelta(.toolCallDelta(index: 0, arguments: #"{"content": "slow result"}"#))
                await childClient.yieldDelta(.finished(usage: nil))
                await childClient.finishStream()
            }
        }

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in chat.stream("Go", context: ctx) {
            events.append(event)
        }

        let subAgentTimedOut = events.contains { event in
            if case let .subAgentCompleted(_, _, result) = event.kind {
                return result.isError && result.content.contains("timed out")
            }
            return false
        }
        #expect(subAgentTimedOut)

        let toolCallTimedOut = events.contains { event in
            if case let .toolCallCompleted(_, _, result) = event.kind {
                return result.isError && result.content.contains("timed out")
            }
            return false
        }
        #expect(toolCallTimedOut)

        #expect(events.contains { $0.kind == .delta("recovered") })
        guard case let .finished(_, _, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(reason == nil)
    }

    @Test
    func cancellationDuringSubAgentTerminatesStream() async throws {
        let tool = BlockingSubAgentTool()
        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "call_block", name: "blocking", arguments: #"{"query": "wait"}"#),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let stream = chat.stream("Go", context: ctx)

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
        #expect(events.contains { event in
            if case let .subAgentStarted(id, name) = event.kind {
                return id == "call_block" && name == "blocking"
            }
            return false
        })
        #expect(!events.contains { if case .subAgentCompleted = $0.kind { return true }; return false })
        #expect(!events.contains { if case .finished = $0.kind { return true }; return false })
    }

    @Test
    func depthLimitSurfacesAsErrorResultInBothCompletionEvents() async throws {
        let childClient = StreamingMockLLMClient(streamSequences: [])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "deep",
            description: "Deep tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "call_deep", name: "deep", arguments: #"{"query": "go"}"#),
            contentTurn("recovered"),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        var events: [StreamEvent] = []
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 2, currentDepth: 2)
        for try await event in chat.stream("Go", context: ctx) {
            events.append(event)
        }

        let subAgentErrored = events.contains { event in
            if case let .subAgentCompleted(id, name, result) = event.kind {
                return id == "call_deep" && name == "deep"
                    && result.isError && result.content.contains("max depth exceeded")
            }
            return false
        }
        #expect(subAgentErrored)

        let toolCallErrored = events.contains { event in
            if case let .toolCallCompleted(id, name, result) = event.kind {
                return id == "call_deep" && name == "deep"
                    && result.isError && result.content.contains("max depth exceeded")
            }
            return false
        }
        #expect(toolCallErrored)

        guard case .finished = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
    }
}

struct ChatSubAgentInheritanceTests {
    @Test
    func inheritParentMessagesDeliversParentTurnsAndControlGetsCleanSlate() async throws {
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)

        let inheritingChildClient = CapturingStreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "cf", name: "finish", arguments: #"{"content": "child done"}"#),
        ])
        let inheritingChildAgent = Agent<SubAgentContext<EmptyContext>>(
            client: inheritingChildClient, tools: [],
            configuration: AgentConfiguration(systemPrompt: "child system")
        )
        let inheritingTool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: inheritingChildAgent,
            inheritParentMessages: true,
            messageBuilder: { $0.query }
        )
        let inheritingParentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "cs", name: "research", arguments: #"{"query": "task"}"#),
            contentTurn("parent done"),
        ])
        let inheritingChat = Chat<SubAgentContext<EmptyContext>>(
            client: inheritingParentClient, tools: [inheritingTool], systemPrompt: "parent system"
        )
        for try await _ in inheritingChat.stream("Go", context: ctx) {}

        let inherited = await inheritingChildClient.capturedMessages
        #expect(inherited == [.system("child system"), .user("Go"), .user("task")])

        let controlChildClient = CapturingStreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "cf", name: "finish", arguments: #"{"content": "child done"}"#),
        ])
        let controlChildAgent = Agent<SubAgentContext<EmptyContext>>(
            client: controlChildClient, tools: [],
            configuration: AgentConfiguration(systemPrompt: "child system")
        )
        let controlTool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: controlChildAgent,
            messageBuilder: { $0.query }
        )
        let controlParentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "cs", name: "research", arguments: #"{"query": "task"}"#),
            contentTurn("parent done"),
        ])
        let controlChat = Chat<SubAgentContext<EmptyContext>>(
            client: controlParentClient, tools: [controlTool], systemPrompt: "parent system"
        )
        for try await _ in controlChat.stream("Go", context: ctx) {}

        let cleanSlate = await controlChildClient.capturedMessages
        #expect(cleanSlate == [.system("child system"), .user("task")])
    }

    @Test
    func malformedInheritedPrefixThrowsOnlyWhenSubAgentRoundBegins() async throws {
        let history: [ChatMessage] = [
            .tool(id: "orphan", name: "lookup", content: "stale"),
            .user("earlier"),
            .assistant(AssistantMessage(content: "earlier answer")),
        ]
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)

        let childClient = StreamingMockLLMClient(streamSequences: [])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: childAgent,
            inheritParentMessages: true,
            messageBuilder: { $0.query }
        )
        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "cs", name: "research", arguments: #"{"query": "task"}"#),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool], maxMessages: 3
        )

        await #expect(throws: AgentError.malformedHistory(.unexpectedToolResult(id: "orphan"))) {
            for try await _ in chat.stream("Go", history: history, context: ctx) {}
        }

        let noopTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "noop",
            description: "No-op",
            executor: { _, _ in NoopOutput() }
        )
        let controlClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "call_noop", name: "noop", arguments: "{}"),
            contentTurn("done"),
        ])
        let controlChat = Chat<SubAgentContext<EmptyContext>>(
            client: controlClient, tools: [noopTool], maxMessages: 3
        )

        var events: [StreamEvent] = []
        for try await event in controlChat.stream("Go", history: history, context: ctx) {
            events.append(event)
        }
        guard case .finished = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
    }

    @Test
    func nonInheritingSubAgentRoundStillValidatesParentHistory() async throws {
        let history: [ChatMessage] = [
            .tool(id: "orphan", name: "lookup", content: "stale"),
            .user("earlier"),
            .assistant(AssistantMessage(content: "earlier answer")),
        ]
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)

        let childClient = StreamingMockLLMClient(streamSequences: [])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: childAgent,
            messageBuilder: { $0.query }
        )
        let parentClient = StreamingMockLLMClient(streamSequences: [
            toolCallTurn(id: "cs", name: "research", arguments: #"{"query": "task"}"#),
        ])
        let chat = Chat<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool], maxMessages: 3
        )

        await #expect(throws: AgentError.malformedHistory(.unexpectedToolResult(id: "orphan"))) {
            for try await _ in chat.stream("Go", history: history, context: ctx) {}
        }
    }
}
