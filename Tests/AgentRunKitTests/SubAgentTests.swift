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

private struct TaggedContext: ToolContext {
    let tag: String
}

struct SubAgentContextTests {
    @Test
    func descendingIncrementsDepth() {
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3, currentDepth: 0)
        let descended = ctx.descending()
        #expect(descended.currentDepth == 1)
        #expect(descended.maxDepth == 3)
    }

    @Test
    func descendingPreservesInner() {
        let ctx = SubAgentContext(inner: TaggedContext(tag: "keep-me"), maxDepth: 5, currentDepth: 2)
        let descended = ctx.descending()
        #expect(descended.inner.tag == "keep-me")
        #expect(descended.currentDepth == 3)
        #expect(descended.maxDepth == 5)
    }

    @Test
    func descendingClearsParentHistory() {
        let messages: [ChatMessage] = [.user("hello"), .assistant(AssistantMessage(content: "hi"))]
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
            .withParentHistory(messages)
        let descended = ctx.descending()
        #expect(descended.parentHistory.isEmpty)
    }
}

struct SubAgentToolTests {
    @Test
    func happyPath() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "Sub-agent result"}"#
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentFinish = ToolCall(
            id: "call_2",
            name: "finish",
            arguments: #"{"content": "Parent done"}"#
        )
        let subAgentCall = ToolCall(
            id: "call_sub",
            name: "research",
            arguments: #"{"query": "test query"}"#
        )
        let parentClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [subAgentCall]),
            AssistantMessage(content: "", toolCalls: [parentFinish])
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient,
            tools: [tool]
        )

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await parentAgent.run(userMessage: "Go", context: ctx)
        #expect(try requireContent(result) == "Parent done")
        #expect(result.iterations == 2)
    }

    @Test
    func depthLimitingBlocksExecution() async throws {
        let childClient = MockLLMClient(responses: [])
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
            _ = try await tool.execute(arguments: args, context: ctx)
            Issue.record("Expected maxDepthExceeded")
        } catch let error as AgentError {
            guard case let .maxDepthExceeded(depth) = error else {
                Issue.record("Expected maxDepthExceeded, got \(error)")
                return
            }
            #expect(depth == 2)
        }
    }

    @Test
    func depthLimitingAllowsWithinBounds() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "OK"}"#
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "shallow",
            description: "Shallow tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let args = try JSONEncoder().encode(QueryParams(query: "test"))
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 2, currentDepth: 1)

        let result = try await tool.execute(arguments: args, context: ctx)
        #expect(result.content == "OK")
    }

    @Test
    func multiLevelNesting() async throws {
        let innerFinish = ToolCall(id: "c1", name: "finish", arguments: #"{"content": "inner result"}"#)
        let innerClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [innerFinish])
        ])
        let innerAgent = Agent<SubAgentContext<EmptyContext>>(client: innerClient, tools: [])

        let innerTool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "inner",
            description: "Inner sub-agent",
            agent: innerAgent,
            messageBuilder: { $0.query }
        )

        let outerFinish = ToolCall(id: "c2", name: "finish", arguments: #"{"content": "outer result"}"#)
        let outerCallInner = ToolCall(id: "c3", name: "inner", arguments: #"{"query": "go deeper"}"#)
        let outerClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [outerCallInner]),
            AssistantMessage(content: "", toolCalls: [outerFinish])
        ])
        let outerAgent = Agent<SubAgentContext<EmptyContext>>(client: outerClient, tools: [innerTool])

        let outerTool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "outer",
            description: "Outer sub-agent",
            agent: outerAgent,
            messageBuilder: { $0.query }
        )

        let rootFinish = ToolCall(id: "c4", name: "finish", arguments: #"{"content": "root done"}"#)
        let rootCallOuter = ToolCall(id: "c5", name: "outer", arguments: #"{"query": "start"}"#)
        let rootClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [rootCallOuter]),
            AssistantMessage(content: "", toolCalls: [rootFinish])
        ])
        let rootAgent = Agent<SubAgentContext<EmptyContext>>(client: rootClient, tools: [outerTool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await rootAgent.run(userMessage: "Go", context: ctx)
        #expect(try requireContent(result) == "root done")
    }

    @Test
    func subAgentBudgetExceededFlowsThroughParent() async throws {
        let childNoopTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "noop",
            description: "No-op",
            executor: { _, _ in NoopOutput() }
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "c0", name: "noop", arguments: "{}")],
                tokenUsage: TokenUsage(input: 100, output: 100)
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "c1", name: "finish", arguments: #"{"content": "x"}"#)]
            )
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [childNoopTool])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "expensive",
            description: "Expensive sub-agent",
            agent: childAgent,
            tokenBudget: 50,
            messageBuilder: { $0.query }
        )

        let subCall = ToolCall(id: "c2", name: "expensive", arguments: #"{"query": "go"}"#)
        let parentFinish = ToolCall(id: "c3", name: "finish", arguments: #"{"content": "recovered"}"#)
        let parentClient = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [subCall]),
            AssistantMessage(content: "", toolCalls: [parentFinish])
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await parentAgent.run(userMessage: "Go", context: ctx)
        #expect(try requireContent(result) == "recovered")

        let captured = await parentClient.capturedMessages
        let toolMessages = captured.compactMap { msg -> String? in
            guard case let .tool(_, _, content) = msg else { return nil }
            return content
        }
        #expect(toolMessages == ["Error: Token budget exceeded (budget: 50, used: 200)."])
    }

    @Test
    func subAgentMaxIterationsReachedFlowsThroughParent() async throws {
        let childClient = MockLLMClient(responses: [
            AssistantMessage(content: "still working")
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient,
            tools: [],
            configuration: AgentConfiguration(maxIterations: 1)
        )

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "stubborn",
            description: "Stubborn sub-agent",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let subCall = ToolCall(id: "c1", name: "stubborn", arguments: #"{"query": "go"}"#)
        let parentFinish = ToolCall(id: "c2", name: "finish", arguments: #"{"content": "recovered"}"#)
        let parentClient = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [subCall]),
            AssistantMessage(content: "", toolCalls: [parentFinish])
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await parentAgent.run(userMessage: "Go", context: ctx)
        #expect(try requireContent(result) == "recovered")

        let captured = await parentClient.capturedMessages
        let toolMessages = captured.compactMap { msg -> String? in
            guard case let .tool(_, _, content) = msg else { return nil }
            return content
        }
        #expect(toolMessages == ["Error: Agent reached maximum iterations (1)."])
    }

    @Test
    func factoryFunctionCreatesEquivalentTool() async throws {
        let finishCall = ToolCall(id: "c1", name: "finish", arguments: #"{"content": "factory result"}"#)
        let childClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool: any AnyTool<SubAgentContext<EmptyContext>> = try subAgentTool(
            name: "via_factory",
            description: "Factory test",
            agent: childAgent,
            messageBuilder: { (params: QueryParams) in params.query }
        )

        #expect(tool.name == "via_factory")

        let args = try JSONEncoder().encode(QueryParams(query: "hello"))
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await tool.execute(arguments: args, context: ctx)
        #expect(result.content == "factory result")
    }

    @Test
    func errorFinishReasonSetsIsError() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "Something went wrong", "reason": "error"}"#
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "failing_sub",
            description: "Sub-agent that finishes with error",
            agent: childAgent,
            messageBuilder: { $0.query }
        )
        let args = try JSONEncoder().encode(QueryParams(query: "test"))
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await tool.execute(arguments: args, context: ctx)
        #expect(result.isError == true)
        #expect(result.content == "Something went wrong")
    }

    @Test
    func customFinishReasonDoesNotSetIsError() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "Partial result", "reason": "partial"}"#
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "partial_sub",
            description: "Sub-agent that finishes with a custom reason",
            agent: childAgent,
            messageBuilder: { $0.query }
        )
        let args = try JSONEncoder().encode(QueryParams(query: "test"))
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await tool.execute(arguments: args, context: ctx)
        #expect(result.isError == false)
        #expect(result.content == "Partial result")
    }

    @Test
    func inheritParentMessagesFalseDoesNotForward() async throws {
        let childFinish = ToolCall(id: "cf", name: "finish", arguments: #"{"content": "child done"}"#)
        let childClient = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [childFinish]),
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient, tools: [],
            configuration: AgentConfiguration(systemPrompt: "child system")
        )
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let subCall = ToolCall(id: "cs", name: "research", arguments: #"{"query": "task"}"#)
        let parentFinish = ToolCall(id: "pf", name: "finish", arguments: #"{"content": "parent done"}"#)
        let parentClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [subCall]),
            AssistantMessage(content: "", toolCalls: [parentFinish]),
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool],
            configuration: AgentConfiguration(systemPrompt: "parent system")
        )

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        _ = try await parentAgent.run(userMessage: "Go", context: ctx)

        let captured = await childClient.capturedMessages
        #expect(captured.count == 2)
        guard case let .system(prompt) = captured[0] else {
            Issue.record("Expected system message")
            return
        }
        #expect(prompt == "child system")
        guard case let .user(msg) = captured[1] else {
            Issue.record("Expected user message")
            return
        }
        #expect(msg == "task")
    }

    @Test
    func nilToolTimeoutBypassesAgentTimeoutInNonStreamingPath() async throws {
        let delayTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "delay",
            description: "Delays",
            executor: { _, _ in
                try await Task.sleep(for: .milliseconds(100))
                return NoopOutput()
            }
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [ToolCall(id: "c0", name: "delay", arguments: "{}")]),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "c1", name: "finish", arguments: #"{"content": "slow done"}"#)]
            ),
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [delayTool])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "slow_sub",
            description: "Slow sub-agent",
            agent: childAgent,
            toolTimeout: nil,
            messageBuilder: { $0.query }
        )

        let subCall = ToolCall(id: "cs", name: "slow_sub", arguments: #"{"query": "go"}"#)
        let parentFinish = ToolCall(id: "pf", name: "finish", arguments: #"{"content": "parent done"}"#)
        let parentClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [subCall]),
            AssistantMessage(content: "", toolCalls: [parentFinish]),
        ])
        let config = AgentConfiguration(toolTimeout: .milliseconds(1))
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool], configuration: config
        )

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await parentAgent.run(userMessage: "Go", context: ctx)
        #expect(try requireContent(result) == "parent done")
    }

    @Test
    func approvalHandlerPropagatesToChildWhenParentPolicyIsNone() async throws {
        let childNoopTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "child_noop",
            description: "Child no-op",
            executor: { _, _ in NoopOutput() }
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "child_tool", name: "child_noop", arguments: "{}")]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "child_finish", name: "finish", arguments: #"{"content":"child done"}"#)]
            ),
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

        let parentClient = MockLLMClient(responses: [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "parent_tool", name: "delegate", arguments: #"{"query":"go"}"#)]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "parent_finish", name: "finish", arguments: #"{"content":"parent done"}"#)]
            ),
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])
        let counter = CountingApprovalHandler()

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await parentAgent.run(
            userMessage: "Go",
            context: ctx,
            approvalHandler: counter.handler
        )

        #expect(try requireContent(result) == "parent done")

        let requests = await counter.requests
        #expect(requests.map(\.toolName) == ["child_noop"])
    }
}

struct SubAgentInheritParentMessagesTests {
    @Test
    func childSeesParentHistory() async throws {
        let childFinish = ToolCall(id: "cf", name: "finish", arguments: #"{"content": "child done"}"#)
        let childClient = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [childFinish]),
        ])
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

        let subCall = ToolCall(id: "cs", name: "research", arguments: #"{"query": "task"}"#)
        let parentFinish = ToolCall(id: "pf", name: "finish", arguments: #"{"content": "parent done"}"#)
        let parentClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [subCall]),
            AssistantMessage(content: "", toolCalls: [parentFinish]),
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool],
            configuration: AgentConfiguration(systemPrompt: "parent system")
        )

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        _ = try await parentAgent.run(userMessage: "Go", context: ctx)

        let captured = await childClient.capturedMessages
        #expect(captured.count == 4)
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
        guard case .assistant = captured[2] else {
            Issue.record("Expected parent assistant message")
            return
        }
        guard case let .user(taskMsg) = captured[3] else {
            Issue.record("Expected child task message last")
            return
        }
        #expect(taskMsg == "task")
    }

    @Test
    func parentSystemMessageStripped() async throws {
        let childFinish = ToolCall(id: "cf", name: "finish", arguments: #"{"content": "child done"}"#)
        let childClient = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [childFinish]),
        ])
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

        let subCall = ToolCall(id: "cs", name: "research", arguments: #"{"query": "task"}"#)
        let parentFinish = ToolCall(id: "pf", name: "finish", arguments: #"{"content": "parent done"}"#)
        let parentClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [subCall]),
            AssistantMessage(content: "", toolCalls: [parentFinish]),
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool],
            configuration: AgentConfiguration(systemPrompt: "parent system")
        )

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        _ = try await parentAgent.run(userMessage: "Go", context: ctx)

        let captured = await childClient.capturedMessages
        let systemMessages = captured.filter(\.isSystem)
        #expect(systemMessages.count == 1)
        guard case let .system(prompt) = systemMessages[0] else {
            Issue.record("Expected system message")
            return
        }
        #expect(prompt == "child system")
    }

    @Test
    func multiTurnParentHistoryInherited() async throws {
        let echoTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "echo",
            description: "Echo",
            executor: { _, _ in NoopOutput() }
        )
        let childFinish = ToolCall(id: "cf", name: "finish", arguments: #"{"content": "child done"}"#)
        let childClient = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [childFinish]),
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient, tools: [],
            configuration: AgentConfiguration(systemPrompt: "child system")
        )
        let subAgentTool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research",
            agent: childAgent,
            inheritParentMessages: true,
            messageBuilder: { $0.query }
        )

        let echoCall1 = ToolCall(id: "e1", name: "echo", arguments: "{}")
        let echoCall2 = ToolCall(id: "e2", name: "echo", arguments: "{}")
        let subCall = ToolCall(id: "cs", name: "research", arguments: #"{"query": "task"}"#)
        let parentFinish = ToolCall(id: "pf", name: "finish", arguments: #"{"content": "parent done"}"#)
        let parentClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [echoCall1]),
            AssistantMessage(content: "", toolCalls: [echoCall2]),
            AssistantMessage(content: "", toolCalls: [subCall]),
            AssistantMessage(content: "", toolCalls: [parentFinish]),
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [echoTool, subAgentTool]
        )

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        _ = try await parentAgent.run(userMessage: "Go", context: ctx)

        let captured = await childClient.capturedMessages
        #expect(captured.count == 8)
        guard case let .system(prompt) = captured[0] else {
            Issue.record("Expected child system first")
            return
        }
        #expect(prompt == "child system")
        guard case let .user(taskMsg) = captured.last else {
            Issue.record("Expected task message last")
            return
        }
        #expect(taskMsg == "task")
        let toolMessages = captured.filter { if case .tool = $0 { return true }; return false }
        #expect(toolMessages.count == 2)
    }

    @Test
    func emptyParentHistoryAtRoot() async throws {
        let childFinish = ToolCall(id: "cf", name: "finish", arguments: #"{"content": "child done"}"#)
        let childClient = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [childFinish]),
        ])
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

        let args = try JSONEncoder().encode(QueryParams(query: "task"))
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let result = try await tool.execute(arguments: args, context: ctx)
        #expect(result.content == "child done")

        let captured = await childClient.capturedMessages
        #expect(captured.count == 2)
        guard case .system = captured[0] else {
            Issue.record("Expected system message")
            return
        }
        guard case .user = captured[1] else {
            Issue.record("Expected user message")
            return
        }
    }
}
