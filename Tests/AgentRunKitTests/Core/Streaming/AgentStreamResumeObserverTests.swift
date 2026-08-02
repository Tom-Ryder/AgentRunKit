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
private func awaitBufferedCursor(_ stream: AgentStream<some ToolContext>, atLeast cursor: UInt64) async {
    for _ in 0 ..< 200 {
        if let bufferedCursor = await stream.bufferedCursor, bufferedCursor >= cursor {
            return
        }
        await Task.yield()
    }
}

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private func makeEchoCallDeltas(id: String, message: String) -> [StreamDelta] {
    [
        .toolCallStart(index: 0, id: id, name: "echo", kind: .function),
        .toolCallDelta(index: 0, arguments: #"{"message":"\#(message)"}"#),
        .finished(usage: TokenUsage(input: 3, output: 2)),
    ]
}

private func makeReplayedIterationEvent(
    iteration: Int,
    history: [ChatMessage],
    sessionID: SessionID,
    runID: RunID,
    checkpointID: CheckpointID
) -> StreamEvent {
    StreamEvent(
        sessionID: sessionID,
        runID: runID,
        origin: .replayed(from: checkpointID),
        kind: .iterationCompleted(usage: TokenUsage(input: 1, output: 1), iteration: iteration, history: history)
    )
}

struct AgentStreamResumeObserverTests {
    @MainActor @Test
    func handleReplayedIterationUpdatesCheckpointCountAndHistory() {
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 8)
        let session = SessionID()
        let runID = RunID()
        let checkpointID = CheckpointID()
        let event = makeReplayedIterationEvent(
            iteration: 1,
            history: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            sessionID: session, runID: runID, checkpointID: checkpointID
        )
        stream.handle(event, toolCallIdPath: [], toolNamePath: [])
        #expect(stream.iterationsReplayed == 1)
        #expect(stream.history.count == 2)
        #expect(stream.currentCheckpoint == checkpointID)
        #expect(stream.sessionID == session)
    }

    @MainActor @Test
    func liveEventsDoNotMutateReplayObservers() {
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 8)
        let liveEvent = StreamEvent(
            sessionID: SessionID(), runID: RunID(), origin: .live,
            kind: .iterationCompleted(
                usage: TokenUsage(input: 1, output: 1), iteration: 1, history: [.user("Hi")]
            )
        )
        stream.handle(liveEvent, toolCallIdPath: [], toolNamePath: [])
        #expect(stream.iterationsReplayed == 0)
        #expect(stream.currentCheckpoint == nil)
        #expect(stream.history.isEmpty)
    }

    @MainActor @Test
    func resetClearsReplayObservers() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "ok"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 1, output: 1),
            iterationUsage: TokenUsage(input: 1, output: 1),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
                [
                    .toolCallStart(index: 0, id: "call_finish_2", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done2"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
            ]),
            tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 64)
        try await stream.resume(from: checkpointID, checkpointer: backend, context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.iterationsReplayed >= 1)

        stream.send("Fresh", context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.iterationsReplayed == 0)
        #expect(stream.currentCheckpoint == nil)
    }

    @MainActor @Test
    func resumePreloadsCheckpointAndContinuesLive() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"continued"}"#),
                    .finished(usage: TokenUsage(input: 7, output: 7)),
                ],
            ]),
            tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 64)
        try await stream.resume(from: checkpointID, checkpointer: backend, context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.iterationsReplayed >= 1)
        #expect(stream.currentCheckpoint == checkpointID)
        #expect(stream.sessionID == session)
        #expect(stream.finishReason == .completed)
    }

    @MainActor @Test
    func resumeSynchronouslyPreloadsCheckpointStateBeforeStreaming() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        let messages: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(content: "first iteration")),
        ]
        try await backend.save(AgentCheckpoint(
            messages: messages,
            iteration: 1,
            tokenUsage: TokenUsage(input: 42, output: 24),
            iterationUsage: TokenUsage(input: 42, output: 24),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"ok"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
            ]),
            tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 64)
        try await stream.resume(from: checkpointID, checkpointer: backend, context: EmptyContext())

        #expect(stream.sessionID == session)
        #expect(stream.history == messages)
        #expect(stream.tokenUsage == TokenUsage(input: 42, output: 24))
        #expect(stream.currentCheckpoint == checkpointID)
    }

    @MainActor @Test
    func resumeReplaysThenContinuesLiveInAgentStream() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "replay"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"live"}"#),
                    .finished(usage: TokenUsage(input: 7, output: 7)),
                ],
            ]),
            tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 64)
        try await stream.resume(from: checkpointID, checkpointer: backend, context: EmptyContext())
        await awaitStreamCompletion(stream)

        let events = try await collect(stream.replay(from: 0))
        let replayedIndex = events.firstIndex { event in
            if case .replayed = event.origin, case .iterationCompleted = event.kind { return true }
            return false
        }
        let liveFinishedIndex = events.firstIndex { event in
            if case .finished = event.kind, event.origin == .live { return true }
            return false
        }
        #expect(replayedIndex != nil)
        #expect(liveFinishedIndex != nil)
        if let replayedIndex, let liveFinishedIndex {
            #expect(replayedIndex < liveFinishedIndex)
        }
    }

    @MainActor @Test
    func resumeRecordsReplayedEventsInBuffer() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "cached"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
            ]),
            tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 64)
        try await stream.resume(from: checkpointID, checkpointer: backend, context: EmptyContext())
        await awaitStreamCompletion(stream)
        let events = try await collect(stream.replay(from: 0))
        guard let firstEvent = events.first else {
            Issue.record("Expected replay buffer to contain resume events")
            return
        }
        #expect(firstEvent.origin == .replayed(from: checkpointID))
        if case let .iterationCompleted(_, iteration, history) = firstEvent.kind {
            #expect(iteration == 1)
            #expect(history == [.user("Hi"), .assistant(AssistantMessage(content: "cached"))])
        } else {
            Issue.record("Expected first buffered event to be replayed iterationCompleted")
        }
        #expect(events.contains { event in
            if case .finished = event.kind, event.origin == .live { return true }
            return false
        })
    }

    @MainActor @Test
    func resumeCancelDropsStaleEvents() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let longSequence: [StreamDelta] = (0 ..< 50).flatMap { index -> [StreamDelta] in
            [.content("event-\(index)")]
        } + [
            .toolCallStart(index: 0, id: "call", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: TokenUsage(input: 1, output: 1)),
        ]
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [longSequence]),
            tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 256)
        try await stream.resume(from: checkpointID, checkpointer: backend, context: EmptyContext())
        await awaitBufferedCursor(stream, atLeast: 2)
        let contentBeforeCancel = stream.content
        let genBeforeCancel = stream.sendGeneration
        stream.cancel()
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(stream.sendGeneration == genBeforeCancel &+ 1)
        #expect(stream.content == contentBeforeCancel)
        #expect(stream.finishReason == nil)
    }

    @MainActor @Test
    func handleReplayedEventUpdatesSessionID() {
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 8)
        let session = SessionID()
        let replayed = StreamEvent(
            sessionID: session,
            runID: RunID(),
            origin: .replayed(from: CheckpointID()),
            kind: .iterationCompleted(
                usage: TokenUsage(input: 1, output: 1), iteration: 1,
                history: [.user("Hi")]
            )
        )
        stream.handle(replayed, toolCallIdPath: [], toolNamePath: [])
        #expect(stream.sessionID == session)
    }

    @MainActor @Test
    func resumeLoadsCheckpointExactlyOnce() async throws {
        let inner = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await inner.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let counting = CountingCheckpointer(inner: inner)
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
            ]),
            tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 64)
        try await stream.resume(from: checkpointID, checkpointer: counting, context: EmptyContext())
        await awaitStreamCompletion(stream)
        let count = await counting.loadCount
        #expect(count == 1)
    }

    @MainActor @Test
    func resumeCancelsInFlightSendBeforePerformingAwaits() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let blocking = SlowCheckpointer(inner: backend)
        let priorSession = SessionID()
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [
                (0 ..< 30).map { _ in StreamDelta.content("x") } + [
                    .toolCallStart(index: 0, id: "call_a", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"prior"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
                [
                    .toolCallStart(index: 0, id: "call_b", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"resumed"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
            ]),
            tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 256)
        stream.send("Hi", context: EmptyContext(), sessionID: priorSession)
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        let priorGen = stream.sendGeneration
        try await stream.resume(from: checkpointID, checkpointer: blocking, context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.sendGeneration > priorGen)
        #expect(stream.sessionID == session)
    }
}

struct AgentStreamCheckpointObservationTests {
    @MainActor @Test
    func currentCheckpointTracksTheMostRecentLiveSave() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [
                makeEchoCallDeltas(id: "call_echo_1", message: "first"),
                makeEchoCallDeltas(id: "call_echo_2", message: "second"),
                [
                    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
            ]),
            tools: [echoTool]
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 64)

        stream.send("Hi", context: EmptyContext(), sessionID: session, checkpointer: backend)
        await awaitStreamCompletion(stream)

        let ids = try await backend.list(session: session)
        #expect(ids.count == 2)
        #expect(stream.currentCheckpoint == ids.last)
    }

    @MainActor @Test
    func staleSaveObservationsAreIgnored() {
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 8)
        stream.observeSavedCheckpoint(CheckpointID(), generation: stream.sendGeneration &- 1)
        #expect(stream.currentCheckpoint == nil)

        let live = CheckpointID()
        stream.observeSavedCheckpoint(live, generation: stream.sendGeneration)
        #expect(stream.currentCheckpoint == live)
    }

    @MainActor @Test
    func refusedTerminalResumePublishesNoTerminalState() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Summarize"), .assistant(AssistantMessage(content: "summarized"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 9, output: 4),
            iterationUsage: TokenUsage(input: 5, output: 2),
            contextBudgetState: nil,
            historyWasRewrittenLocally: false,
            sessionAllowlist: [],
            sessionID: SessionID(),
            runID: RunID(),
            checkpointID: checkpointID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            mcpToolBindings: [],
            terminalOutcome: AgentTerminalOutcome(content: "shipped", toolName: "finalize")
        ))
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 8)

        await #expect(
            throws: AgentCheckpointError.completionToolMismatch(checkpointed: "finalize", live: nil)
        ) {
            try await stream.resume(from: checkpointID, checkpointer: backend, context: EmptyContext())
        }

        #expect(stream.terminalContent == nil)
        #expect(stream.finishReason == nil)
        #expect(stream.history.isEmpty)
        #expect(stream.currentCheckpoint == nil)
        #expect(!stream.isStreaming)
    }

    @MainActor @Test
    func aSendDuringResumeKeepsCheckpointStateOutOfTheStream() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointSession = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Checkpointed"), .assistant(AssistantMessage(content: "earlier"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 42, output: 24),
            iterationUsage: TokenUsage(input: 42, output: 24),
            sessionID: checkpointSession, runID: RunID(), checkpointID: checkpointID
        ))
        let freshFinish: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"fresh"}"#),
            .finished(usage: TokenUsage(input: 1, output: 1)),
        ]
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [freshFinish, freshFinish]), tools: []
        )
        let stream = AgentStream(agent: agent, bufferCapacity: 64)
        let gate = GatedLoadCheckpointer(inner: backend)

        let resumeTask = Task {
            try await stream.resume(from: checkpointID, checkpointer: gate, context: EmptyContext())
        }
        await gate.awaitLoadStarted()
        stream.send("Fresh", context: EmptyContext())
        await gate.releaseLoad()
        try await resumeTask.value
        await awaitStreamCompletion(stream)

        #expect(stream.content == "fresh")
        #expect(stream.terminalContent == "fresh")
        #expect(stream.tokenUsage == TokenUsage(input: 1, output: 1))
        #expect(stream.history.contains(.user("Fresh")))
        #expect(!stream.history.contains(.user("Checkpointed")))
        #expect(stream.sessionID != checkpointSession)
        #expect(stream.currentCheckpoint == nil)
        #expect(stream.iterationsReplayed == 0)
    }
}

private actor CountingCheckpointer: AgentCheckpointer {
    private let inner: any AgentCheckpointer
    private(set) var loadCount = 0

    init(inner: any AgentCheckpointer) {
        self.inner = inner
    }

    func save(_ checkpoint: AgentCheckpoint) async throws {
        try await inner.save(checkpoint)
    }

    func load(_ id: CheckpointID) async throws -> AgentCheckpoint {
        loadCount += 1
        return try await inner.load(id)
    }

    func list(session: SessionID) async throws -> [CheckpointID] {
        try await inner.list(session: session)
    }
}

private actor GatedLoadCheckpointer: AgentCheckpointer {
    private let inner: any AgentCheckpointer
    private var loadStarted = false
    private var loadStartedContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(inner: any AgentCheckpointer) {
        self.inner = inner
    }

    func save(_ checkpoint: AgentCheckpoint) async throws {
        try await inner.save(checkpoint)
    }

    func load(_ id: CheckpointID) async throws -> AgentCheckpoint {
        loadStarted = true
        loadStartedContinuation?.resume()
        loadStartedContinuation = nil

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return try await inner.load(id)
    }

    func list(session: SessionID) async throws -> [CheckpointID] {
        try await inner.list(session: session)
    }

    func awaitLoadStarted() async {
        guard !loadStarted else { return }
        precondition(loadStartedContinuation == nil, "awaitLoadStarted supports a single waiter")
        await withCheckedContinuation { continuation in
            loadStartedContinuation = continuation
        }
    }

    func releaseLoad() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SlowCheckpointer: AgentCheckpointer {
    private let inner: any AgentCheckpointer

    init(inner: any AgentCheckpointer) {
        self.inner = inner
    }

    func save(_ checkpoint: AgentCheckpoint) async throws {
        try await inner.save(checkpoint)
    }

    func load(_ id: CheckpointID) async throws -> AgentCheckpoint {
        try await Task.sleep(for: .milliseconds(20))
        return try await inner.load(id)
    }

    func list(session: SessionID) async throws -> [CheckpointID] {
        try await inner.list(session: session)
    }
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}
