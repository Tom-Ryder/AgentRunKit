@testable import AgentRunKit
import Foundation
import Testing

struct StreamEventOriginPropagationTests {
    private func uuid(_ value: String) throws -> UUID {
        try #require(UUID(uuidString: value))
    }

    @Test
    func withOriginPreservesEveryField() throws {
        let id = try EventID(rawValue: uuid("00000000-0000-0000-0000-000000000701"))
        let timestamp = Date(timeIntervalSince1970: 1_774_880_530)
        let sessionID = try SessionID(rawValue: uuid("00000000-0000-0000-0000-000000000702"))
        let runID = try RunID(rawValue: uuid("00000000-0000-0000-0000-000000000703"))
        let parentEventID = try EventID(rawValue: uuid("00000000-0000-0000-0000-000000000704"))
        let original = StreamEvent(
            id: id,
            timestamp: timestamp,
            sessionID: sessionID,
            runID: runID,
            parentEventID: parentEventID,
            origin: .live,
            kind: .delta("payload")
        )
        let checkpointID = try CheckpointID(rawValue: uuid("00000000-0000-0000-0000-000000000705"))
        let copy = original.with(origin: .replayed(from: checkpointID))

        #expect(copy.id == original.id)
        #expect(copy.timestamp == original.timestamp)
        #expect(copy.sessionID == original.sessionID)
        #expect(copy.runID == original.runID)
        #expect(copy.parentEventID == original.parentEventID)
        #expect(copy.kind == original.kind)
        #expect(copy.origin == .replayed(from: checkpointID))
    }

    @MainActor @Test
    func handleRecursesIntoNestedSubAgentEvent() throws {
        let client = StreamingMockLLMClient(streamSequences: [])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent)

        let nested = StreamEvent(kind: .toolCallStarted(name: "child-tool", id: "child-id"))
        let outer = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000711")),
            origin: .replayed(from: CheckpointID(rawValue: uuid("00000000-0000-0000-0000-000000000712"))),
            kind: .subAgentEvent(toolCallId: "parent-tc", toolName: "parent-tool", event: nested)
        )

        stream.handle(outer, toolCallIdPath: [], toolNamePath: [])

        #expect(stream.toolCalls.count == 1)
        #expect(stream.toolCalls[0].id == "parent-tc/child-id")
        #expect(stream.toolCalls[0].name == "parent-tool > child-tool")
    }

    @Test
    func historyEmissionRewritePreservesReplayedOrigin() {
        let checkpointID = CheckpointID()
        let nested = StreamEvent(
            origin: .replayed(from: checkpointID),
            kind: .iterationCompleted(
                usage: TokenUsage(input: 1, output: 1),
                iteration: 1,
                history: [.user("Hello")]
            )
        )
        let outer = StreamEvent(
            origin: .replayed(from: checkpointID),
            kind: .subAgentEvent(toolCallId: "tc", toolName: "delegate", event: nested)
        )
        let configuration = AgentConfiguration(historyEmissionDepthLimit: 0)
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []),
            tools: [],
            configuration: configuration
        )
        let processed = agent.applyHistoryEmissionLimitToSubAgentEvent(outer, parentDepth: 0)
        #expect(processed.origin == .replayed(from: checkpointID))
        if case let .subAgentEvent(_, _, rewrittenNested) = processed.kind {
            #expect(rewrittenNested.origin == .replayed(from: checkpointID))
        } else {
            Issue.record("Expected subAgentEvent kind")
        }
    }
}
