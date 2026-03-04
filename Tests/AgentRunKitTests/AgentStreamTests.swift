import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct AgentStreamTests {
    @MainActor
    private func makeStream(
        streamSequences: [[StreamDelta]]
    ) -> AgentStream<EmptyContext> {
        let client = StreamingMockLLMClient(streamSequences: streamSequences)
        let agent = Agent<EmptyContext>(client: client, tools: [])
        return AgentStream(agent: agent)
    }

    @MainActor
    private func makeStreamWithTools(
        streamSequences: [[StreamDelta]],
        tools: [any AnyTool<EmptyContext>]
    ) -> AgentStream<EmptyContext> {
        let client = StreamingMockLLMClient(streamSequences: streamSequences)
        let agent = Agent<EmptyContext>(client: client, tools: tools)
        return AgentStream(agent: agent)
    }

    @MainActor
    private func awaitCompletion(_ stream: AgentStream<EmptyContext>) async {
        while stream.isStreaming {
            await Task.yield()
        }
    }

    @MainActor @Test
    func contentAccumulatesFromDeltas() async throws {
        let deltas: [StreamDelta] = [
            .content("Hello"),
            .content(" world"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeStream(streamSequences: [deltas])

        stream.send("Hi", context: EmptyContext())
        await awaitCompletion(stream)

        #expect(stream.content == "Hello world")
    }

    @MainActor @Test
    func reasoningDeltaAccumulates() async throws {
        let deltas: [StreamDelta] = [
            .reasoning("Let me "),
            .reasoning("think"),
            .content("Answer"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeStream(streamSequences: [deltas])

        stream.send("Think", context: EmptyContext())
        await awaitCompletion(stream)

        #expect(stream.reasoning == "Let me think")
        #expect(stream.content == "Answer")
    }

    @MainActor @Test
    func toolCallLifecycle() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "hello"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let stream = makeStreamWithTools(
            streamSequences: [firstDeltas, secondDeltas],
            tools: [echoTool]
        )

        stream.send("Echo hello", context: EmptyContext())
        await awaitCompletion(stream)

        let echoCall = stream.toolCalls.first { $0.name == "echo" }
        #expect(echoCall != nil)
        if case let .completed(result) = echoCall?.state {
            #expect(result.contains("Echo: hello"))
        } else {
            Issue.record("Expected completed state for echo tool")
        }
    }

    @MainActor @Test
    func toolCallFailureState() async throws {
        let failTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "fail_tool",
            description: "Always fails",
            executor: { _, _ in throw AgentError.toolNotFound(name: "oops") }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "fail_tool"),
            .toolCallDelta(index: 0, arguments: #"{"message": "test"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Failed"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let stream = makeStreamWithTools(
            streamSequences: [firstDeltas, secondDeltas],
            tools: [failTool]
        )

        stream.send("Do it", context: EmptyContext())
        await awaitCompletion(stream)

        let failCall = stream.toolCalls.first { $0.name == "fail_tool" }
        #expect(failCall != nil)
        if case .failed = failCall?.state {
            // expected
        } else {
            Issue.record("Expected failed state for fail_tool")
        }
    }

    @MainActor @Test
    func finishedSetsTokenUsageAndHistory() async throws {
        let deltas: [StreamDelta] = [
            .content("Result"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "All done", "reason": "completed"}"#),
            .finished(usage: TokenUsage(input: 50, output: 25)),
        ]
        let stream = makeStream(streamSequences: [deltas])

        stream.send("Go", context: EmptyContext())
        await awaitCompletion(stream)

        #expect(stream.tokenUsage?.input == 50)
        #expect(stream.tokenUsage?.output == 25)
        #expect(stream.finishReason == .completed)
        #expect(!stream.history.isEmpty)
    }

    @MainActor @Test
    func sendResetsState() async throws {
        let deltas1: [StreamDelta] = [
            .content("First"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done1"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let deltas2: [StreamDelta] = [
            .content("Second"),
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done2"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [deltas1, deltas2])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent)

        stream.send("First", context: EmptyContext())
        await awaitCompletion(stream)
        #expect(stream.content == "First")

        stream.send("Second", context: EmptyContext())
        await awaitCompletion(stream)
        #expect(stream.content == "Second")
        #expect(stream.tokenUsage?.input == 20)
    }

    @MainActor @Test
    func cancelStopsStreaming() async throws {
        let deltas: [StreamDelta] = [
            .content("Hello"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeStream(streamSequences: [deltas])

        stream.send("Hi", context: EmptyContext())
        stream.cancel()
        await awaitCompletion(stream)

        #expect(!stream.isStreaming)
    }

    @MainActor @Test
    func errorSurfacedOnStreamFailure() async throws {
        let client = FailingStreamMockLLMClient()
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent)

        stream.send("Hi", context: EmptyContext())
        await awaitCompletion(stream)

        #expect(stream.error != nil)
        #expect(!stream.isStreaming)
    }

    @MainActor @Test
    func isStreamingLifecycle() async throws {
        let deltas: [StreamDelta] = [
            .content("Hello"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeStream(streamSequences: [deltas])

        #expect(!stream.isStreaming)
        stream.send("Hi", context: EmptyContext())
        #expect(stream.isStreaming)

        await awaitCompletion(stream)
        #expect(!stream.isStreaming)
    }

    @MainActor @Test
    func finishContentUsedWhenNoDeltaContent() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "fallback result"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeStream(streamSequences: [deltas])

        stream.send("Hi", context: EmptyContext())
        await awaitCompletion(stream)

        #expect(stream.content == "fallback result")
    }

    @MainActor @Test
    func finishContentIgnoredWhenDeltaContentExists() async throws {
        let deltas: [StreamDelta] = [
            .content("From deltas"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "from finish"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeStream(streamSequences: [deltas])

        stream.send("Hi", context: EmptyContext())
        await awaitCompletion(stream)

        #expect(stream.content == "From deltas")
    }
}

private struct EchoParams: Codable, SchemaProviding, Sendable {
    let message: String
    static var jsonSchema: JSONSchema { .object(properties: ["message": .string()], required: ["message"]) }
}

private struct EchoOutput: Codable, Sendable {
    let echoed: String
}

private actor FailingStreamMockLLMClient: LLMClient {
    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        throw AgentError.llmError(.other("Not implemented"))
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AgentError.llmError(.other("Stream failure")))
        }
    }
}
