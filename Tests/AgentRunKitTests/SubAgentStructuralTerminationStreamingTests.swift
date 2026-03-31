@testable import AgentRunKit
import Foundation
import Testing

private struct QueryParams: Codable, SchemaProviding {
    let query: String

    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

struct SubAgentStructuralStreamTests {
    @Test
    func childMaxIterationsReachedSurfacesAsParentToolError() async throws {
        let childDeltas: [StreamDelta] = [
            .content("child working"),
            .finished(usage: nil),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas])
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

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_stubborn", name: "stubborn"),
            .toolCallDelta(index: 0, arguments: #"{"query": "go"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "parent_finish", name: "finish"),
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

        #expect(containsNestedFinishedEvent(
            events,
            toolName: "stubborn",
            reason: .maxIterationsReached(limit: 1)
        ))

        guard let subAgentResult = findSubAgentCompletedResult(events, name: "stubborn") else {
            Issue.record("Expected sub-agent completion result")
            return
        }
        #expect(subAgentResult.isError)
        #expect(subAgentResult.content == "Error: Agent reached maximum iterations (1).")

        guard let toolResult = findToolCallCompletedResult(events, id: "call_stubborn", name: "stubborn") else {
            Issue.record("Expected tool completion result")
            return
        }
        #expect(toolResult.isError)
        #expect(toolResult.content == "Error: Agent reached maximum iterations (1).")

        guard case let .finished(_, content, _, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "recovered")
    }

    @Test
    func childTokenBudgetExceededSurfacesAsParentToolError() async throws {
        let childDeltas: [StreamDelta] = [
            .content("child working"),
            .finished(usage: TokenUsage(input: 40, output: 40)),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "expensive",
            description: "Expensive sub-agent",
            agent: childAgent,
            tokenBudget: 50,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_expensive", name: "expensive"),
            .toolCallDelta(index: 0, arguments: #"{"query": "go"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "parent_finish", name: "finish"),
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

        #expect(containsNestedFinishedEvent(
            events,
            toolName: "expensive",
            reason: .tokenBudgetExceeded(budget: 50, used: 80)
        ))

        guard let subAgentResult = findSubAgentCompletedResult(events, name: "expensive") else {
            Issue.record("Expected sub-agent completion result")
            return
        }
        #expect(subAgentResult.isError)
        #expect(subAgentResult.content == "Error: Token budget exceeded (budget: 50, used: 80).")

        guard let toolResult = findToolCallCompletedResult(events, id: "call_expensive", name: "expensive") else {
            Issue.record("Expected tool completion result")
            return
        }
        #expect(toolResult.isError)
        #expect(toolResult.content == "Error: Token budget exceeded (budget: 50, used: 80).")

        guard case let .finished(_, content, _, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "recovered")
    }
}

private func containsNestedFinishedEvent(_ events: [StreamEvent], toolName: String, reason: FinishReason) -> Bool {
    events.contains { event in
        if case let .subAgentEvent(_, eventName, innerEvent) = event.kind,
           eventName == toolName,
           case let .finished(_, content, eventReason, _) = innerEvent.kind {
            return content == nil && eventReason == reason
        }
        return false
    }
}

private func findSubAgentCompletedResult(_ events: [StreamEvent], name: String) -> ToolResult? {
    for event in events {
        if case let .subAgentCompleted(_, eventName, result) = event.kind, eventName == name {
            return result
        }
    }
    return nil
}

private func findToolCallCompletedResult(_ events: [StreamEvent], id: String, name: String) -> ToolResult? {
    for event in events {
        if case let .toolCallCompleted(eventId, eventName, result) = event.kind,
           eventId == id,
           eventName == name {
            return result
        }
    }
    return nil
}
