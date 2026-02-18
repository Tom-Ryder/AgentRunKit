import Foundation
import Testing

@testable import AgentRunKit

private struct QueryParams: Codable, SchemaProviding, Sendable {
    let query: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

private struct NoopParams: Codable, SchemaProviding, Sendable {
    static var jsonSchema: JSONSchema { .object(properties: [:], required: []) }
}

private struct NoopOutput: Codable, Sendable {}

@Suite
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
        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 5, currentDepth: 2)
        let descended = ctx.descending()
        #expect(descended.currentDepth == 3)
        #expect(descended.maxDepth == 5)
    }
}

@Suite
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
        #expect(result.content == "Parent done")
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
        #expect(result.content == "root done")
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
        #expect(result.content == "recovered")

        let captured = await parentClient.capturedMessages
        let toolMessages = captured.compactMap { msg -> String? in
            guard case let .tool(_, _, content) = msg else { return nil }
            return content
        }
        let errorMessage = toolMessages.first { $0.contains("budget") }
        #expect(errorMessage != nil)
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
}
