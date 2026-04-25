@testable import AgentRunKit
import Foundation
import Testing

private struct QueryParams: Codable, SchemaProviding {
    let query: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

private let childTerminalDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "child done"}"#),
    .finished(usage: TokenUsage(input: 1, output: 1)),
]

private let parentFinishDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "parent_finish", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "parent done"}"#),
    .finished(usage: TokenUsage(input: 1, output: 1)),
]

private func subAgentInvocationDeltas(callID: String) -> [StreamDelta] {
    [
        .toolCallStart(index: 0, id: callID, name: "research", kind: .function),
        .toolCallDelta(index: 0, arguments: #"{"query": "x"}"#),
        .finished(usage: TokenUsage(input: 1, output: 1)),
    ]
}

private func makeChildAgent() -> Agent<SubAgentContext<EmptyContext>> {
    let client = StreamingMockLLMClient(streamSequences: [childTerminalDeltas])
    return Agent<SubAgentContext<EmptyContext>>(client: client, tools: [])
}

private func makeResearchTool(child: Agent<SubAgentContext<EmptyContext>>) throws
    -> SubAgentTool<QueryParams, EmptyContext> {
    try SubAgentTool<QueryParams, EmptyContext>(
        name: "research",
        description: "Research tool",
        agent: child,
        messageBuilder: { $0.query }
    )
}

struct SubAgentRunIdentityTests {
    @Test
    func subAgentEventsShareParentSessionAndUseChildRun() async throws {
        let tool = try makeResearchTool(child: makeChildAgent())
        let parentClient = StreamingMockLLMClient(streamSequences: [
            subAgentInvocationDeltas(callID: "call_sub"), parentFinishDeltas,
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        var parentSessionIDs = Set<SessionID>()
        var nestedSessionIDs = Set<SessionID>()
        var nestedRunIDs = Set<RunID>()
        var parentRunIDs = Set<RunID>()
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            if let parentSession = event.sessionID { parentSessionIDs.insert(parentSession) }
            if let parentRun = event.runID { parentRunIDs.insert(parentRun) }
            if case let .subAgentEvent(_, _, nested) = event.kind {
                if let nestedSession = nested.sessionID { nestedSessionIDs.insert(nestedSession) }
                if let nestedRun = nested.runID { nestedRunIDs.insert(nestedRun) }
            }
        }

        #expect(parentSessionIDs.count == 1)
        #expect(parentRunIDs.count == 1)
        #expect(nestedSessionIDs == parentSessionIDs)
        #expect(nestedRunIDs.count == 1)
        #expect(nestedRunIDs.isDisjoint(with: parentRunIDs))
    }

    @Test
    func subAgentWrapperUsesParentRun() async throws {
        let tool = try makeResearchTool(child: makeChildAgent())
        let parentClient = StreamingMockLLMClient(streamSequences: [
            subAgentInvocationDeltas(callID: "call_sub"), parentFinishDeltas,
        ])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        var wrapperRunIDs = Set<RunID>()
        var topLevelRunIDs = Set<RunID>()
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            if case .subAgentEvent = event.kind {
                if let runID = event.runID { wrapperRunIDs.insert(runID) }
            } else if case .iterationCompleted = event.kind {
                if let runID = event.runID { topLevelRunIDs.insert(runID) }
            }
        }

        #expect(!wrapperRunIDs.isEmpty)
        #expect(wrapperRunIDs == topLevelRunIDs)
    }

    @Test
    func siblingSubAgentsUseDistinctRuns() async throws {
        let twoCalls: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_a", name: "research", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"query": "a"}"#),
            .toolCallStart(index: 1, id: "call_b", name: "research", kind: .function),
            .toolCallDelta(index: 1, arguments: #"{"query": "b"}"#),
            .finished(usage: nil),
        ]
        let twoChildClient = StreamingMockLLMClient(streamSequences: [
            childTerminalDeltas, childTerminalDeltas,
        ])
        let twoChildAgent = Agent<SubAgentContext<EmptyContext>>(client: twoChildClient, tools: [])
        let twoChildTool = try makeResearchTool(child: twoChildAgent)
        let parentClient = StreamingMockLLMClient(streamSequences: [twoCalls, parentFinishDeltas])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [twoChildTool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        var nestedRunsByToolCallID: [String: Set<RunID>] = [:]
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            if case let .subAgentEvent(toolCallID, _, nested) = event.kind, let nestedRunID = nested.runID {
                nestedRunsByToolCallID[toolCallID, default: []].insert(nestedRunID)
            }
        }

        #expect(nestedRunsByToolCallID.count == 2)
        let runA = nestedRunsByToolCallID["call_a"] ?? []
        let runB = nestedRunsByToolCallID["call_b"] ?? []
        #expect(runA.count == 1)
        #expect(runB.count == 1)
        #expect(runA.isDisjoint(with: runB))
    }
}
