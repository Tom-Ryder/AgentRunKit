@testable import AgentRunKit
import Foundation
import Testing

@MainActor
private func awaitStreamCompletion(_ stream: AgentStream<some ToolContext>) async {
    while stream.isStreaming {
        await Task.yield()
    }
}

@MainActor
private func waitForBufferedCursor(
    _ stream: AgentStream<some ToolContext>,
    atLeast threshold: UInt64,
    timeout: Duration = .seconds(2)
) async {
    let deadline = ContinuousClock().now + timeout
    while ContinuousClock().now < deadline {
        if let value = await stream.bufferedCursor, value >= threshold { return }
        await Task.yield()
    }
}

private func collectReplay(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private let firstSendDeltas: [StreamDelta] = [
    .content("first"),
    .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done1"}"#),
    .finished(usage: TokenUsage(input: 10, output: 5)),
]

private let secondSendDeltas: [StreamDelta] = [
    .content("second"),
    .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done2"}"#),
    .finished(usage: TokenUsage(input: 20, output: 10)),
]

@MainActor
private func makeBufferedStream(
    sequences: [[StreamDelta]] = [firstSendDeltas],
    capacity: Int? = 64
) -> AgentStream<EmptyContext> {
    let client = StreamingMockLLMClient(streamSequences: sequences)
    let agent = Agent<EmptyContext>(client: client, tools: [])
    return AgentStream(agent: agent, bufferCapacity: capacity)
}

struct AgentStreamReplayTests {
    @MainActor @Test
    func bufferDisabledReplayThrowsBufferDisabled() async {
        let stream = makeBufferedStream(capacity: nil)
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        do {
            _ = try await collectReplay(stream.replay(from: 0))
            Issue.record("Expected BufferReplayError.bufferDisabled")
        } catch BufferReplayError.bufferDisabled {
        } catch {
            Issue.record("Expected BufferReplayError.bufferDisabled, got \(error)")
        }
    }

    @MainActor @Test
    func bufferEnabledReplayYieldsRecordedEvents() async throws {
        let stream = makeBufferedStream()
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        let events = try await collectReplay(stream.replay(from: 0))
        let deltaEvent = events.first { event in
            if case .delta("first") = event.kind { return true }
            return false
        }
        #expect(deltaEvent != nil)

        guard let finishedEvent = events.last(where: { event in
            if case .finished = event.kind { return true }
            return false
        }), case let .finished(usage, content, _, _) = finishedEvent.kind else {
            Issue.record("Expected .finished event in replay")
            return
        }
        #expect(content == "done1")
        #expect(usage == TokenUsage(input: 10, output: 5))

        let cursor = await stream.bufferedCursor
        #expect(cursor == UInt64(events.count))
    }

    @MainActor @Test
    func cursorBasedReplayPreservesEnvelopeIdentity() async throws {
        let stream = makeBufferedStream()
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        let allEvents = try await collectReplay(stream.replay(from: 0))
        #expect(allEvents.count >= 2)

        let tail = try await collectReplay(stream.replay(from: 1))
        #expect(tail.count == allEvents.count - 1)
        #expect(tail.first?.id == allEvents[1].id)
    }

    @MainActor @Test
    func backToBackSendsDoNotLeakBufferEvents() async throws {
        let stream = makeBufferedStream(sequences: [firstSendDeltas, secondSendDeltas])

        stream.send("First", context: EmptyContext())
        await awaitStreamCompletion(stream)

        stream.send("Second", context: EmptyContext())
        await awaitStreamCompletion(stream)

        let events = try await collectReplay(stream.replay(from: 0))
        guard let finishEvent = events.last(where: { event in
            if case .finished = event.kind { return true }
            return false
        }), case let .finished(_, finishContent, _, _) = finishEvent.kind else {
            Issue.record("Expected finished event in replay")
            return
        }
        #expect(finishContent == "done2")

        for event in events {
            if case let .delta(text) = event.kind {
                #expect(text != "first")
            }
        }
    }

    @MainActor @Test
    func midStreamCancelThenNewSendShowsOnlyNewSendInBuffer() async throws {
        let stream = makeBufferedStream(sequences: [firstSendDeltas, secondSendDeltas])

        stream.send("First", context: EmptyContext())
        await waitForBufferedCursor(stream, atLeast: 1)

        stream.cancel()

        stream.send("Second", context: EmptyContext())
        await awaitStreamCompletion(stream)

        let events = try await collectReplay(stream.replay(from: 0))
        let deltaTexts = events.compactMap { event -> String? in
            if case let .delta(text) = event.kind { return text }
            return nil
        }
        #expect(!deltaTexts.contains("first"))
        #expect(deltaTexts.contains("second"))
    }

    @MainActor @Test
    func cancelBumpsSendGenerationToInvalidateInFlightTask() {
        let stream = makeBufferedStream()
        stream.send("Hi", context: EmptyContext())
        let generationAfterSend = stream.sendGeneration
        stream.cancel()
        #expect(stream.sendGeneration == generationAfterSend &+ 1)
    }

    @MainActor @Test
    func cancelPreventsFurtherObservableStateMutations() async {
        let longSequence: [StreamDelta] = (0 ..< 50).flatMap { index -> [StreamDelta] in
            [.content("event-\(index)")]
        } + [
            .toolCallStart(index: 0, id: "call", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 1, output: 1)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [longSequence])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent, bufferCapacity: 256)

        stream.send("Hi", context: EmptyContext())
        await waitForBufferedCursor(stream, atLeast: 1)
        let contentSnapshot = stream.content
        stream.cancel()

        for _ in 0 ..< 100 {
            await Task.yield()
        }

        #expect(stream.content == contentSnapshot)
        #expect(stream.finishReason == nil)
    }

    @MainActor @Test
    func replayIterationCanBeAbandonedWithoutResourceLeak() async throws {
        let stream = makeBufferedStream()
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        var firstReplayed: StreamEvent?
        for try await event in stream.replay(from: 0) {
            firstReplayed = event
            break
        }
        #expect(firstReplayed != nil)

        let events = try await collectReplay(stream.replay(from: 0))
        #expect(events.count > 1)
        #expect(events.first?.id == firstReplayed?.id)
    }

    @MainActor @Test
    func agentStreamDeallocatesAfterCancel() async {
        weak var weakStream: AgentStream<EmptyContext>?

        autoreleasepool {
            let stream = makeBufferedStream()
            weakStream = stream
            stream.send("Hi", context: EmptyContext())
            stream.cancel()
        }

        for _ in 0 ..< 200 {
            await Task.yield()
            if weakStream == nil { break }
        }
        #expect(weakStream == nil)
    }
}
