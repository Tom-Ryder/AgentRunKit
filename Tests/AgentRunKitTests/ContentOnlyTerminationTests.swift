@testable import AgentRunKit
import Foundation
import Testing

struct AgentContentOnlyStreamTests {
    @Test
    func streamTerminatesOnContentOnlyIterationForContentOnlyClient() async throws {
        let deltas: [StreamDelta] = [
            .content("The answer is 42."),
            .finished(usage: TokenUsage(input: 3, output: 5))
        ]
        let client = ContentOnlyTerminatingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Q", context: EmptyContext()) {
            events.append(event)
        }

        let deltaEvents = events.filter {
            if case .delta = $0.kind { true } else { false }
        }
        #expect(deltaEvents.count == 1)
        #expect(deltaEvents.first?.kind == .delta("The answer is 42."))

        guard case let .finished(tokenUsage, content, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(tokenUsage == TokenUsage(input: 3, output: 5))
        #expect(content == "The answer is 42.")
        #expect(reason == .completed)

        let invocationCount = await client.invocationCount
        #expect(invocationCount == 1)
    }

    @Test
    func streamDoesNotTerminateOnContentOnlyForRegularClient() async throws {
        let deltas: [StreamDelta] = [
            .content("still thinking"),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas, deltas, deltas])
        let config = AgentConfiguration(maxIterations: 3)
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Q", context: EmptyContext()) {
            events.append(event)
        }

        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == nil)
        #expect(reason == .maxIterationsReached(limit: 3))
    }

    @Test
    func finishToolStillFiresWhenContentOnlyClientAlsoEmitsContent() async throws {
        let deltas: [StreamDelta] = [
            .content("model text"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(
                index: 0,
                arguments: #"{"content": "finish-tool content", "reason": "completed"}"#
            ),
            .finished(usage: TokenUsage(input: 1, output: 2))
        ]
        let client = ContentOnlyTerminatingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Q", context: EmptyContext()) {
            events.append(event)
        }

        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "finish-tool content")
        #expect(reason == .completed)
    }
}
