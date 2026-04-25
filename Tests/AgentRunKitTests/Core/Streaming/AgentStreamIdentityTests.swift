@testable import AgentRunKit
import Foundation
import Testing

@MainActor
private func awaitStreamCompletion(_ stream: AgentStream<some ToolContext>) async {
    while stream.isStreaming {
        await Task.yield()
    }
}

private let finishOnceDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
    .finished(usage: TokenUsage(input: 1, output: 1)),
]

@MainActor
private func makeStream(streamSequences: [[StreamDelta]] = [finishOnceDeltas]) -> AgentStream<EmptyContext> {
    let client = StreamingMockLLMClient(streamSequences: streamSequences)
    let agent = Agent<EmptyContext>(client: client, tools: [])
    return AgentStream(agent: agent)
}

struct AgentStreamIdentityTests {
    @MainActor @Test
    func sendUsesExplicitSessionID() async {
        let explicit = SessionID()
        let stream = makeStream()
        stream.send("Hi", context: EmptyContext(), sessionID: explicit)
        await awaitStreamCompletion(stream)
        #expect(stream.sessionID == explicit)
    }

    @MainActor @Test
    func sendWithoutExplicitSessionObservesMintedSession() async {
        let stream = makeStream()
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.sessionID != nil)
    }

    @MainActor @Test
    func secondSendWithoutExplicitSessionUsesFreshSession() async throws {
        let stream = makeStream(streamSequences: [finishOnceDeltas, finishOnceDeltas])
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)
        let firstSession = try #require(stream.sessionID)

        stream.send("Hello", context: EmptyContext())
        await awaitStreamCompletion(stream)
        let secondSession = try #require(stream.sessionID)

        #expect(firstSession != secondSession)
    }

    @MainActor @Test
    func secondSendWithSameExplicitSessionUsesFreshRun() async throws {
        let explicit = SessionID()
        let client = StreamingMockLLMClient(streamSequences: [finishOnceDeltas, finishOnceDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent, bufferCapacity: 32)

        stream.send("Hi", context: EmptyContext(), sessionID: explicit)
        await awaitStreamCompletion(stream)
        let firstReplay = try await collect(stream.replay(from: 0))

        stream.send("Hello", context: EmptyContext(), sessionID: explicit)
        await awaitStreamCompletion(stream)
        let secondReplay = try await collect(stream.replay(from: 0))

        let firstRunIDs = Set(firstReplay.compactMap(\.runID))
        let secondRunIDs = Set(secondReplay.compactMap(\.runID))
        #expect(stream.sessionID == explicit)
        #expect(!firstRunIDs.isEmpty)
        #expect(!secondRunIDs.isEmpty)
        #expect(firstRunIDs.isDisjoint(with: secondRunIDs))
    }
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}
