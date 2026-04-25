@testable import AgentRunKit
import Testing

private let promptTooLongError = AgentError.llmError(
    .httpError(statusCode: 400, body: "context_length_exceeded")
)

private let testFactory = StreamEventFactory(sessionID: nil, runID: nil, origin: .live)

private struct ScriptedStreamClient: LLMClient {
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
        var totalUsage = TokenUsage()
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
        var totalUsage = TokenUsage()
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
        var totalUsage = TokenUsage()
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
        let processor = StreamProcessor(client: client, toolDefinitions: [], policy: .agent, eventFactory: testFactory)
        let (_, eventContinuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsage()
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
        var totalUsage = TokenUsage()

        let iteration = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
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
        var totalUsage = TokenUsage()

        let iteration = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
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
        var totalUsage = TokenUsage()

        let iteration = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
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
        var totalUsage = TokenUsage()

        await #expect(throws: AgentError.malformedStream(.conflictingAssistantContinuity)) {
            _ = try await processor.process(
                messages: [.user("Hi")],
                totalUsage: &totalUsage,
                continuation: eventContinuation
            )
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
        var totalUsage = TokenUsage()
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
