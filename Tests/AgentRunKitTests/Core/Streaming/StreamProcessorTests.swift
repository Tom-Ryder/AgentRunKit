@testable import AgentRunKit
import Testing

private let promptTooLongError = AgentError.llmError(
    .httpError(statusCode: 400, body: "context_length_exceeded")
)

private let testFactory = StreamEventFactory(sessionID: nil, runID: nil, origin: .live)

private struct ScriptedStreamClient: LLMClient {
    let providerIdentifier: ProviderIdentifier = .custom("ScriptedStreamClient")
    let deltas: [StreamDelta]
    let error: (any Error)?

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        AssistantMessage(content: "")
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let deltas = deltas
        let error = error
        let (stream, continuation) = AsyncThrowingStream<StreamDelta, Error>.makeStream()
        for delta in deltas {
            continuation.yield(delta)
        }
        continuation.finish(throwing: error)
        return stream
    }
}

struct StreamProcessorEmittedOutputTests {
    @Test
    func errorBeforeAnyDeltaSetsEmittedOutputFalse() async {
        let client = ScriptedStreamClient(deltas: [], error: promptTooLongError)
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = true

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                emittedOutput: &emittedOutput,
                continuation: eventContinuation
            )
            Issue.record("Expected error")
        } catch {
            #expect(!emittedOutput)
        }
    }

    @Test
    func errorAfterContentDeltaSetsEmittedOutputTrue() async {
        let client = ScriptedStreamClient(
            deltas: [.content("hello")],
            error: promptTooLongError
        )
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = false

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                emittedOutput: &emittedOutput,
                continuation: eventContinuation
            )
            Issue.record("Expected error")
        } catch {
            #expect(emittedOutput)
        }
    }

    @Test
    func toolCallStartUnderChatPolicySetsEmittedOutput() async {
        let client = ScriptedStreamClient(
            deltas: [.toolCallStart(index: 0, id: "call_1", name: "search", kind: .function)],
            error: promptTooLongError
        )
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = false

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                emittedOutput: &emittedOutput,
                continuation: eventContinuation
            )
            Issue.record("Expected error")
        } catch {
            #expect(emittedOutput)
        }
    }

    @Test
    func terminalToolUnderAgentPolicyDoesNotSetEmittedOutput() async {
        let client = ScriptedStreamClient(
            deltas: [.toolCallStart(index: 0, id: "finish_1", name: "finish", kind: .function)],
            error: promptTooLongError
        )
        let processor = StreamProcessor(
            client: client, toolDefinitions: [], policy: .agent(.builtInFinish), eventFactory: testFactory
        )
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = true

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                emittedOutput: &emittedOutput,
                continuation: eventContinuation
            )
            Issue.record("Expected error")
        } catch {
            #expect(!emittedOutput)
        }
    }
}

struct StreamPolicyDerivationTests {
    @Test
    func builtInFinishSuppressesTheStartEventForOnlyTheReservedTool() {
        let policy = StreamPolicy.agent(.builtInFinish)

        #expect(!policy.shouldEmitToolStart(name: "finish"))
        #expect(policy.shouldEmitToolStart(name: "search"))
    }

    @Test
    func customCompletionAndReservedFinishBothEmitStartEvents() {
        let policy = StreamPolicy.agent(.executableTool(name: "finalize"))

        #expect(policy.shouldEmitToolStart(name: "finalize"))
        #expect(policy.shouldEmitToolStart(name: "finish"))
    }

    @Test
    func customCompletionToolStreamsAnOrdinaryStartEvent() async throws {
        let client = ScriptedStreamClient(
            deltas: [
                .toolCallStart(index: 0, id: "call_1", name: "finalize", kind: .function),
                .toolCallDelta(index: 0, arguments: "{}"),
                .finished(usage: nil),
            ],
            error: nil
        )
        let processor = StreamProcessor(
            client: client, toolDefinitions: [],
            policy: .agent(.executableTool(name: "finalize")), eventFactory: testFactory
        )
        let (events, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = false

        let iteration = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
            emittedOutput: &emittedOutput,
            continuation: eventContinuation
        )
        eventContinuation.finish()

        #expect(iteration.toolCalls == [ToolCall(id: "call_1", name: "finalize", arguments: "{}")])
        var kinds: [StreamEvent.Kind] = []
        for try await event in events {
            kinds.append(event.kind)
        }
        #expect(kinds == [.toolCallStarted(name: "finalize", id: "call_1")])
    }
}

struct StreamProcessorCompletionTests {
    @Test
    func streamEndingWithoutFinishedDeltaThrowsFinishedDeltaMissing() async {
        let client = ScriptedStreamClient(
            deltas: [.content("partial")],
            error: nil
        )
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = false

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                emittedOutput: &emittedOutput,
                continuation: eventContinuation
            )
            Issue.record("Expected finishedDeltaMissing error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error else {
                Issue.record("Expected llmError, got \(error)")
                return
            }
            guard case let .streamFailed(.finishedDeltaMissing(diagnostics)) = transport else {
                Issue.record("Expected finishedDeltaMissing, got \(transport)")
                return
            }
            #expect(diagnostics.eventsObserved == 1)
            #expect(emittedOutput)
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
    }
}

struct StreamProcessorToolCallAccumulationTests {
    @Test
    func duplicateToolCallStartDoesNotResetAccumulatedArguments() async throws {
        let client = ScriptedStreamClient(
            deltas: [
                .toolCallStart(index: 0, id: "call_1", name: "web_search", kind: .function),
                .toolCallDelta(index: 0, arguments: #"{"searches":["#),
                .toolCallStart(index: 0, id: "call_1", name: "web_search", kind: .function),
                .toolCallDelta(index: 0, arguments: #""swift"]}"#),
                .finished(usage: nil),
            ],
            error: nil
        )
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = false

        let iteration = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
            emittedOutput: &emittedOutput,
            continuation: eventContinuation
        )

        #expect(iteration.toolCalls == [
            ToolCall(
                id: "call_1",
                name: "web_search",
                arguments: #"{"searches":["swift"]}"#
            )
        ])
    }
}

struct StreamProcessorContinuityTests {
    @Test
    func finalizedContinuityPersistsIntoAssistantMessage() async throws {
        let continuity = AssistantContinuity(
            substrate: .responses,
            payload: .object(["response_id": .string("resp_123")])
        )
        let client = ContinuityStreamingMockLLMClient(streamSequences: [[
            .delta(.content("hello")),
            .finalizedContinuity(continuity),
            .delta(.finished(usage: nil)),
        ]])
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = false

        let iteration = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
            emittedOutput: &emittedOutput,
            continuation: eventContinuation
        )

        #expect(iteration.toAssistantMessage() == AssistantMessage(content: "hello", continuity: continuity))
    }

    @Test
    func streamWithoutFinalizedContinuityStillProducesNilContinuity() async throws {
        let client = ScriptedStreamClient(
            deltas: [.content("hello"), .finished(usage: nil)],
            error: nil
        )
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = false

        let iteration = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
            emittedOutput: &emittedOutput,
            continuation: eventContinuation
        )

        #expect(iteration.toAssistantMessage().continuity == nil)
    }

    @Test
    func conflictingFinalizedContinuityThrowsMalformedStream() async {
        let first = AssistantContinuity(
            substrate: .responses,
            payload: .object(["response_id": .string("resp_123")])
        )
        let second = AssistantContinuity(
            substrate: .responses,
            payload: .object(["response_id": .string("resp_456")])
        )
        let client = ContinuityStreamingMockLLMClient(streamSequences: [[
            .finalizedContinuity(first),
            .finalizedContinuity(second),
        ]])
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = false

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                emittedOutput: &emittedOutput,
                continuation: eventContinuation
            )
            Issue.record("Expected conflicting assistant continuity")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.malformedStream(reason, diagnostics))) = error else {
                Issue.record("Expected malformed stream, got \(error)")
                return
            }
            #expect(reason == .conflictingAssistantContinuity)
            #expect(diagnostics.eventsObserved == 0)
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
    }

    @Test
    func failedStreamAfterFinalizedContinuityDoesNotCountAsEmittedOutput() async {
        let continuity = AssistantContinuity(
            substrate: .responses,
            payload: .object(["response_id": .string("resp_123")])
        )
        let client = ContinuityStreamingMockLLMClient(
            streamSequences: [[.finalizedContinuity(continuity)]],
            streamErrors: [promptTooLongError]
        )
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsageTotals()
        var emittedOutput = true

        do {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                emittedOutput: &emittedOutput,
                continuation: eventContinuation
            )
            Issue.record("Expected error")
        } catch {
            #expect(!emittedOutput)
        }
    }
}

private struct StreamProcessorAccountingTests {
    @Test(arguments: [TokenUsage(input: 10, output: 5, cacheRead: 0), nil])
    func successfulDrainRecordsOnlyTheFinalUsageSnapshot(usage: TokenUsage?) async throws {
        let client = ScriptedStreamClient(
            deltas: [
                .content("done"), .finished(usage: TokenUsage(input: 90, output: 90)),
                .finished(usage: usage),
            ],
            error: nil
        )
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        defer { continuation.finish() }
        var totals = TokenUsageTotals()
        var emittedOutput = false
        let iteration = try await processor.process(
            messages: [.user("Hi")], totalUsage: &totals,
            emittedOutput: &emittedOutput, continuation: continuation
        )
        #expect(iteration.content == "done" && iteration.usage == usage)
        #expect(totals.input == (usage == nil ? 0 : 10))
        #expect(totals.output == (usage == nil ? 0 : 5))
        #expect(totals.coverage == (usage == nil ? .unavailable : .complete))
        #expect(totals.cacheRead == (usage == nil ? nil : 0))
        #expect(totals.cacheReadCoverage == (usage == nil ? .unavailable : .complete))
    }

    @Test(arguments: [
        ScriptedStreamClient(deltas: [.finished(usage: TokenUsage(input: 90, output: 90))],
                             error: promptTooLongError),
        ScriptedStreamClient(deltas: [.finished(usage: TokenUsage(input: 90, output: 90))],
                             error: CancellationError()),
        ScriptedStreamClient(deltas: [.toolCallDelta(index: 1, arguments: "{}"),
                                      .finished(usage: TokenUsage(input: 90, output: 90))], error: nil),
        ScriptedStreamClient(deltas: [.content("unfinished")], error: nil),
    ])
    func failedDrainPreservesExistingTotals(client: ScriptedStreamClient) async throws {
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .chat, eventFactory: testFactory)
        let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        defer { continuation.finish() }
        var totals = makeTokenUsageTotals(TokenUsage(input: 7, output: 3, cacheRead: 0), nil)
        let original = totals
        var emittedOutput = false
        await #expect(throws: (any Error).self) {
            try await processor.process(
                messages: [.user("Hi")], totalUsage: &totals,
                emittedOutput: &emittedOutput, continuation: continuation
            )
        }
        #expect(totals == original)
        #expect(totals.input == 7 && totals.output == 3)
        #expect(totals.coverage == .partial && totals.cacheReadCoverage == .partial)
        #expect(totals.cacheRead == 0)
    }
}
