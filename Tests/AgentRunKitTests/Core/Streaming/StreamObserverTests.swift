@testable import AgentRunKit
import Foundation
import Testing

private let observerFactory = StreamEventFactory(sessionID: nil, runID: nil, origin: .live)

private enum ObserverStreamStep {
    case deltas([StreamDelta])
    case hangingAfterDeltas([StreamDelta])
    case error(any Error)
}

private struct ObserverTestError: Error {}

/// @unchecked Sendable justification: observer callbacks cross concurrency domains and
/// NSLock guards all shared mutable state in this test recorder.
private final class StreamObserverRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var streamEvents: [StreamEvent] = []
    private var streamCompletions: [StreamCompletion] = []

    func record(event: StreamEvent) {
        lock.withLock {
            streamEvents.append(event)
        }
    }

    func record(completion: StreamCompletion) {
        lock.withLock {
            streamCompletions.append(completion)
        }
    }

    var events: [StreamEvent] {
        lock.withLock { streamEvents }
    }

    var completions: [StreamCompletion] {
        lock.withLock { streamCompletions }
    }

    func waitForCompletions(_ count: Int) async {
        for _ in 0 ..< 100 {
            if completions.count >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    var requestContext: RequestContext {
        RequestContext(
            onStreamEvent: { self.record(event: $0) },
            onStreamComplete: { self.record(completion: $0) }
        )
    }

    var completionOnlyRequestContext: RequestContext {
        RequestContext(onStreamComplete: { self.record(completion: $0) })
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private actor ObserverScriptedClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("ObserverScriptedClient")
    let contextWindowSize: Int?
    private let streamSteps: [ObserverStreamStep]
    private let generateResponses: [AssistantMessage]
    private var streamIndex = 0
    private var generateIndex = 0

    init(
        streamSteps: [ObserverStreamStep],
        generateResponses: [AssistantMessage] = [],
        contextWindowSize: Int? = nil
    ) {
        self.streamSteps = streamSteps
        self.generateResponses = generateResponses
        self.contextWindowSize = contextWindowSize
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        defer { generateIndex += 1 }
        guard generateIndex < generateResponses.count else {
            throw AgentError.llmError(.other("No more generate responses"))
        }
        return generateResponses[generateIndex]
    }

    func nextStreamStep() -> ObserverStreamStep {
        let step = streamIndex < streamSteps.count ? streamSteps[streamIndex] : .deltas([])
        streamIndex += 1
        return step
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch await self.nextStreamStep() {
                case let .deltas(deltas):
                    for delta in deltas {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                case let .hangingAfterDeltas(deltas):
                    for delta in deltas {
                        continuation.yield(delta)
                    }
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(60))
                        }
                        continuation.finish(throwing: CancellationError())
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: error)
                    }
                case let .error(error):
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct StreamObserverTests {
    @Test
    func successObservesEventsAndOneCompletion() async throws {
        let recorder = StreamObserverRecorder()
        let client = ObserverScriptedClient(streamSteps: [.deltas([
            .content("hello"),
            .reasoning("plan"),
            .toolCallStart(index: 0, id: "call_1", name: "lookup", kind: .function),
            .audioStarted(id: "audio_1", expiresAt: 12),
            .audioData(Data([1, 2, 3])),
            .audioTranscript("spoken"),
            .finished(usage: nil),
        ])])
        let processor = StreamProcessor(
            client: client,
            toolDefinitions: [],
            policy: .chat,
            eventFactory: observerFactory
        )
        let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsage()

        _ = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
            continuation: continuation,
            requestContext: recorder.requestContext
        )

        #expect(recorder.events.map(\.kind) == [
            .delta("hello"),
            .reasoningDelta("plan"),
            .toolCallStarted(name: "lookup", id: "call_1"),
            .audioData(Data([1, 2, 3])),
            .audioTranscript("spoken"),
            .audioFinished(id: "audio_1", expiresAt: 12, data: Data([1, 2, 3])),
        ])
        guard case let .success(diagnostics) = try #require(recorder.completions.first) else {
            Issue.record("Expected success completion")
            return
        }
        #expect(recorder.completions.count == 1)
        #expect(diagnostics.eventsObserved == 6)
    }

    @Test
    func streamFailuresObserveFailedCompletion() async {
        let failures: [StreamFailure] = [
            .idleTimeout(diagnostics: .empty),
            .providerTerminationMissing(diagnostics: .empty),
            .finishedDeltaMissing(diagnostics: .empty),
            .midStreamTransportFailure(code: .timedOut, diagnostics: .empty),
            .providerError(provider: .anthropic, code: "overloaded_error", message: "Overloaded"),
            .malformedStream(reason: .finalizedSemanticStateDiverged, diagnostics: .empty),
        ]

        for failure in failures {
            let recorder = StreamObserverRecorder()
            let client = ObserverScriptedClient(streamSteps: [.error(AgentError.llmError(.streamFailed(failure)))])
            let processor = StreamProcessor(
                client: client,
                toolDefinitions: [],
                policy: .chat,
                eventFactory: observerFactory
            )
            let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
            var totalUsage = TokenUsage()

            do {
                _ = try await processor.process(
                    messages: [.user("Hi")],
                    totalUsage: &totalUsage,
                    continuation: continuation,
                    requestContext: recorder.completionOnlyRequestContext
                )
                Issue.record("Expected stream failure")
            } catch let error as AgentError {
                #expect(error == AgentError.llmError(.streamFailed(failure)))
                #expect(recorder.completions == [.failed(failure)])
            } catch {
                Issue.record("Expected AgentError, got \(error)")
            }
        }
    }

    @Test
    func frameworkStreamFailuresObserveFailedCompletion() async {
        let recorder = StreamObserverRecorder()
        let client = ObserverScriptedClient(streamSteps: [.deltas([.content("partial")])])
        let processor = StreamProcessor(
            client: client,
            toolDefinitions: [],
            policy: .chat,
            eventFactory: observerFactory
        )
        let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsage()

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                continuation: continuation,
                requestContext: recorder.completionOnlyRequestContext
            )
            Issue.record("Expected finishedDeltaMissing")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.finishedDeltaMissing(diagnostics))) = error else {
                Issue.record("Expected finishedDeltaMissing, got \(error)")
                return
            }
            #expect(recorder.completions == [.failed(.finishedDeltaMissing(diagnostics: diagnostics))])
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
    }

    @Test
    func orphanedToolArgumentsObserveFailedCompletion() async {
        let recorder = StreamObserverRecorder()
        let client = ObserverScriptedClient(streamSteps: [.deltas([
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: nil),
        ])])
        let processor = StreamProcessor(
            client: client,
            toolDefinitions: [],
            policy: .chat,
            eventFactory: observerFactory
        )
        let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsage()

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                continuation: continuation,
                requestContext: recorder.completionOnlyRequestContext
            )
            Issue.record("Expected orphaned tool arguments")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.malformedStream(reason, diagnostics))) = error else {
                Issue.record("Expected malformed stream, got \(error)")
                return
            }
            #expect(reason == .orphanedToolCallArguments(indices: [0]))
            #expect(recorder.completions == [.failed(.malformedStream(reason: reason, diagnostics: diagnostics))])
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
    }

    @Test
    func nonStreamErrorsDoNotObserveCompletion() async {
        let recorder = StreamObserverRecorder()
        let client = ObserverScriptedClient(streamSteps: [.error(ObserverTestError())])
        let processor = StreamProcessor(
            client: client,
            toolDefinitions: [],
            policy: .chat,
            eventFactory: observerFactory
        )
        let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsage()

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                continuation: continuation,
                requestContext: recorder.completionOnlyRequestContext
            )
            Issue.record("Expected non-stream error")
        } catch is ObserverTestError {
            #expect(recorder.completions.isEmpty)
        } catch {
            Issue.record("Expected ObserverTestError, got \(error)")
        }
    }

    @Test
    func cancellationErrorObservesCancelledCompletion() async {
        let recorder = StreamObserverRecorder()
        let client = ObserverScriptedClient(streamSteps: [.error(CancellationError())])
        let processor = StreamProcessor(
            client: client,
            toolDefinitions: [],
            policy: .chat,
            eventFactory: observerFactory
        )
        let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsage()

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                continuation: continuation,
                requestContext: recorder.completionOnlyRequestContext
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(recorder.completions == [.cancelled])
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func consumerCancellationObservesCancelledCompletion() async throws {
        let recorder = StreamObserverRecorder()
        let client = ObserverScriptedClient(streamSteps: [.hangingAfterDeltas([.content("partial")])])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let task = Task {
            var iterator = agent.stream(
                userMessage: "Go",
                context: EmptyContext(),
                requestContext: recorder.completionOnlyRequestContext
            ).makeAsyncIterator()
            _ = try await iterator.next()
            try await Task.sleep(for: .seconds(60))
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.result
        await recorder.waitForCompletions(1)
        #expect(recorder.completions == [.cancelled])
    }

    @Test
    func reactiveRetryObservesOneFailureAndOneSuccess() async throws {
        let recorder = StreamObserverRecorder()
        let promptTooLong = StreamFailure.providerError(
            provider: .anthropic,
            code: "invalid_request_error",
            message: "prompt is too long: 200001 tokens > 200000 maximum"
        )
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"recovered"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let client = ObserverScriptedClient(
            streamSteps: [
                .error(AgentError.llmError(.streamFailed(promptTooLong))),
                .deltas(finishDeltas),
            ],
            generateResponses: [AssistantMessage(
                content: "Summary of earlier work",
                tokenUsage: TokenUsage(input: 20, output: 10)
            )],
            contextWindowSize: 1000
        )
        let agent = Agent<EmptyContext>(
            client: client,
            tools: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        let history: [ChatMessage] = [
            .user("earlier"),
            .assistant(AssistantMessage(content: "reply")),
            .user("more"),
            .assistant(AssistantMessage(content: "another")),
        ]

        var events: [StreamEvent] = []
        for try await event in agent.stream(
            userMessage: "Go",
            history: history,
            context: EmptyContext(),
            requestContext: recorder.completionOnlyRequestContext
        ) {
            events.append(event)
        }

        guard case let .finished(_, content, _, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "recovered")
        #expect(recorder.completions.count == 2)
        #expect(recorder.completions.first == .failed(promptTooLong))
        guard case let .success(diagnostics) = recorder.completions.last else {
            Issue.record("Expected retry success")
            return
        }
        #expect(diagnostics.eventsObserved == 0)
    }

    @Test
    func resumeReplayDoesNotFireStreamObservers() async throws {
        let recorder = StreamObserverRecorder()
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: SessionID(),
            runID: RunID(),
            checkpointID: checkpointID
        ))
        let client = ObserverScriptedClient(streamSteps: [.deltas([
            .content("live"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: TokenUsage(input: 1, output: 1)),
        ])])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in try await agent.resume(
            from: checkpointID,
            checkpointer: backend,
            context: EmptyContext(),
            requestContext: recorder.requestContext
        ) {
            events.append(event)
        }

        #expect(events.contains { event in
            if case .iterationCompleted = event.kind, case .replayed = event.origin { return true }
            return false
        })
        #expect(recorder.events.map(\.kind) == [.delta("live")])
        #expect(recorder.completions.count == 1)
    }
}
