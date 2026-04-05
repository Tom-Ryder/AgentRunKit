@testable import AgentRunKit
import Foundation
import Testing

struct ChatTests {
    @Test
    func streamSimpleResponseWithoutTools() async throws {
        let deltas: [StreamDelta] = [
            .content("Hello "),
            .content("world!"),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let chat = Chat<EmptyContext>(client: client)

        var events: [StreamEvent] = []
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.count == 3)
        #expect(events[0].kind == .delta("Hello "))
        #expect(events[1].kind == .delta("world!"))
        guard case let .finished(tokenUsage, content, reason, history) = events[2].kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(tokenUsage == TokenUsage(input: 10, output: 5))
        #expect(content == nil)
        #expect(reason == nil)
        #expect(history.count == 2)
    }

    @Test
    func emittedEventsCarryStage1EnvelopeMetadata() async throws {
        let deltas: [StreamDelta] = [
            .content("Hello "),
            .content("world!"),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let chat = Chat<EmptyContext>(client: client)

        let startedAt = Date()
        var events: [StreamEvent] = []
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            events.append(event)
        }
        let endedAt = Date()

        #expect(!events.isEmpty)
        StreamEventInvariantAssertions.assertStage1RuntimeInvariants(
            events,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    @Test
    func streamWithToolCallAndContinuation() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .content("Let me "),
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message":"#),
            .toolCallDelta(index: 0, arguments: #""hello"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]

        let secondStreamDeltas: [StreamDelta] = [
            .content("The echo result was: Echo: hello"),
            .finished(usage: TokenUsage(input: 20, output: 10))
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [echoTool])

        var events: [StreamEvent] = []
        for try await event in chat.stream("Use echo", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.contains { $0.kind == .delta("Let me ") })
        #expect(events.contains { $0.kind == .toolCallStarted(name: "echo", id: "call_1") })

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, name, result) = event.kind {
                return name == "echo" && result.content.contains("Echo: hello")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)

        #expect(events.contains { $0.kind == .delta("The echo result was: Echo: hello") })

        guard case let .finished(tokenUsage, _, _, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(tokenUsage.input == 30)
        #expect(tokenUsage.output == 15)
    }

    @Test
    func handleToolExecutionErrorGracefully() async throws {
        let failingTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "failing",
            description: "Always fails",
            executor: { _, _ in throw TestToolError.intentional }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "failing"),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]

        let secondStreamDeltas: [StreamDelta] = [
            .content("Tool failed, but I recovered"),
            .finished(usage: TokenUsage(input: 20, output: 10))
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [failingTool])

        var events: [StreamEvent] = []
        for try await event in chat.stream("Run failing tool", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, name, result) = event.kind {
                return name == "failing" && result.isError
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }

    @Test
    func handleToolNotFoundGracefully() async throws {
        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "nonexistent"),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]

        let secondStreamDeltas: [StreamDelta] = [
            .content("Tool not found"),
            .finished(usage: TokenUsage(input: 20, output: 10))
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in chat.stream("Run nonexistent", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, _, result) = event.kind {
                return result.isError && result.content.contains("does not exist")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }

    @Test
    func respectsCancellation() async throws {
        let client = ControllableStreamingMockLLMClient()
        let chat = Chat<EmptyContext>(client: client)

        let streamStarted = AsyncStream<Void>.makeStream()
        await client.setStreamStartedHandler { streamStarted.continuation.yield() }

        let collector = StreamingEventCollector()
        let task = Task {
            for try await event in chat.stream("Hi", context: EmptyContext()) {
                await collector.append(event)
            }
        }

        for await _ in streamStarted.stream {
            break
        }

        await client.yieldDelta(.content("First"))
        await client.yieldDelta(.content("Second"))
        await collector.waitForFirstEvent()

        task.cancel()

        do {
            try await task.value
        } catch is CancellationError {
            // Expected
        } catch {
            // Other errors during cancellation are acceptable
        }

        let events = await collector.events
        #expect(events.count >= 1, "Should have received at least one event before cancellation")
        #expect(events.count <= 2, "Should not have received events after cancellation")
    }

    @Test
    func nonStreamingSendWorks() async throws {
        let client = GenerateOnlyMockLLMClient(responses: [
            AssistantMessage(content: "Hello from send!", tokenUsage: TokenUsage(input: 5, output: 3))
        ])
        let chat = Chat<EmptyContext>(client: client)

        let (response, _) = try await chat.send("Hi")

        #expect(response.content == "Hello from send!")
        #expect(response.tokenUsage?.input == 5)
        #expect(response.tokenUsage?.output == 3)
    }

    @Test
    func systemPromptIncludedInMessages() async throws {
        let client = CapturingStreamingMockLLMClient(streamSequences: [[
            .content("Response"),
            .finished(usage: nil)
        ]])
        let chat = Chat<EmptyContext>(client: client, systemPrompt: "You are helpful.")

        var events: [StreamEvent] = []
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            events.append(event)
        }

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 2)
        guard case let .system(prompt) = capturedMessages[0] else {
            Issue.record("Expected system message first")
            return
        }
        #expect(prompt == "You are helpful.")
        guard case let .user(content) = capturedMessages[1] else {
            Issue.record("Expected user message second")
            return
        }
        #expect(content == "Hi")
    }

    @Test
    func sendReturnsHistoryWithResponse() async throws {
        let client = GenerateOnlyMockLLMClient(responses: [
            AssistantMessage(content: "Response", tokenUsage: TokenUsage(input: 5, output: 3))
        ])
        let chat = Chat<EmptyContext>(client: client, systemPrompt: "System")

        let (response, history) = try await chat.send("Hello")

        #expect(response.content == "Response")
        #expect(history.count == 3)
        guard case .system = history[0] else {
            Issue.record("Expected system message first")
            return
        }
        guard case .user = history[1] else {
            Issue.record("Expected user message second")
            return
        }
        guard case .assistant = history[2] else {
            Issue.record("Expected assistant message third")
            return
        }
    }

    @Test
    func streamReasoningDeltasEmittedAndAccumulated() async throws {
        let deltas: [StreamDelta] = [
            .reasoning("Let me think..."),
            .reasoning(" Yes, I see."),
            .content("Here is my answer."),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let chat = Chat<EmptyContext>(client: client)

        var events: [StreamEvent] = []
        var finalHistory: [ChatMessage] = []
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            events.append(event)
            if case let .finished(_, _, _, history) = event.kind {
                finalHistory = history
            }
        }

        #expect(events.contains { $0.kind == .reasoningDelta("Let me think...") })
        #expect(events.contains { $0.kind == .reasoningDelta(" Yes, I see.") })
        #expect(events.contains { $0.kind == .delta("Here is my answer.") })

        let assistantMessage = finalHistory.compactMap { msg -> AssistantMessage? in
            if case let .assistant(assistant) = msg { return assistant }
            return nil
        }.first
        #expect(assistantMessage?.reasoning?.content == "Let me think... Yes, I see.")
    }

    @Test
    func sendWithHistoryIncludesPreviousMessages() async throws {
        let client = ChatCapturingMockLLMClient(responses: [
            AssistantMessage(content: "Second response")
        ])
        let chat = Chat<EmptyContext>(client: client)
        let previousHistory: [ChatMessage] = [
            .user("First message"),
            .assistant(AssistantMessage(content: "First response"))
        ]

        let (_, newHistory) = try await chat.send("Second message", history: previousHistory)

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 3)
        guard case let .user(first) = capturedMessages[0] else {
            Issue.record("Expected first user message")
            return
        }
        #expect(first == "First message")
        guard case .assistant = capturedMessages[1] else {
            Issue.record("Expected assistant message second")
            return
        }
        guard case let .user(second) = capturedMessages[2] else {
            Issue.record("Expected second user message")
            return
        }
        #expect(second == "Second message")
        #expect(newHistory.count == 4)
    }

    @Test
    func reusingUnresolvedToolCallHistoryThrows() async throws {
        let firstClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "lookup", arguments: "{}"),
            ]),
        ])
        let firstChat = Chat<EmptyContext>(client: firstClient)
        let (_, history) = try await firstChat.send("First message")

        let secondClient = ChatCapturingMockLLMClient(responses: [
            AssistantMessage(content: "unreachable"),
        ])
        let secondChat = Chat<EmptyContext>(client: secondClient)

        await #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
            _ = try await secondChat.send("Second message", history: history)
        }
    }

    @Test
    func replayingUserDefinedFinishToolHistoryRemainsValid() async throws {
        let finishTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "finish",
            description: "User-defined finish tool",
            executor: { params, _ in EchoOutput(echoed: "Finish: \(params.message)") }
        )
        let lookupTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "lookup",
            description: "Lookup tool",
            executor: { params, _ in EchoOutput(echoed: "Lookup: \(params.message)") }
        )
        let history: [ChatMessage] = [
            .user("First message"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "finish_1", name: "finish", arguments: #"{"message":"done"}"#),
                ToolCall(id: "lookup_1", name: "lookup", arguments: #"{"message":"details"}"#),
            ])),
            .tool(id: "finish_1", name: "finish", content: "Finish: done"),
            .tool(id: "lookup_1", name: "lookup", content: "Lookup: details"),
        ]

        let secondClient = ChatCapturingMockLLMClient(responses: [
            AssistantMessage(content: "Second response"),
        ])
        let secondChat = Chat<EmptyContext>(client: secondClient, tools: [finishTool, lookupTool])

        _ = try await secondChat.send("Second message", history: history)

        let capturedMessages = await secondClient.capturedMessages
        #expect(capturedMessages.count == 5)
        guard case let .assistant(message) = capturedMessages[1] else {
            Issue.record("Expected assistant history entry")
            return
        }
        #expect(message.toolCalls.map(\.name) == ["finish", "lookup"])
        guard case .tool(id: "finish_1", name: "finish", content: "Finish: done") = capturedMessages[2] else {
            Issue.record("Expected finish tool result to remain in history")
            return
        }
        guard case .tool(id: "lookup_1", name: "lookup", content: "Lookup: details") = capturedMessages[3] else {
            Issue.record("Expected lookup tool result to remain in history")
            return
        }
    }

    @Test
    func streamMaxToolRoundsProducesStructuralFinishedEvent() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let loopDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message":"loop"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [loopDeltas, loopDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [echoTool], maxToolRounds: 2)

        var events: [StreamEvent] = []
        for try await event in chat.stream("Go", context: EmptyContext()) {
            events.append(event)
        }

        guard case let .finished(tokenUsage, content, reason, history) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(tokenUsage == TokenUsage(input: 20, output: 10))
        #expect(content == nil)
        #expect(reason == .maxIterationsReached(limit: 2))
        #expect(history.count == 5)
    }
}

private actor ChatCapturingMockLLMClient: LLMClient {
    private let responses: [AssistantMessage]
    private var callIndex = 0
    private(set) var capturedMessages: [ChatMessage] = []

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        capturedMessages = messages
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

struct ChatStreamingEdgeTests {
    @Test
    func outOfOrderDeltasBuffered() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallDelta(index: 0, arguments: #"{"mes"#),
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"sage":"hello"}"#),
            .finished(usage: nil)
        ]

        let secondStreamDeltas: [StreamDelta] = [
            .content("Done"),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [echoTool])

        var toolCallCompletedEvent: StreamEvent?
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            if case .toolCallCompleted = event.kind {
                toolCallCompletedEvent = event
            }
        }

        guard case let .toolCallCompleted(id, name, result) = toolCallCompletedEvent?.kind else {
            Issue.record("Expected toolCallCompleted event")
            return
        }
        #expect(id == "call_1")
        #expect(name == "echo")
        #expect(result.content.contains("Echo: hello"))
    }

    @Test
    func emptyStreamFinishesGracefully() async throws {
        let deltas: [StreamDelta] = [
            .finished(usage: TokenUsage(input: 5, output: 3))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let chat = Chat<EmptyContext>(client: client)

        var events: [StreamEvent] = []
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.count == 1)
        guard case let .finished(tokenUsage, _, _, _) = events.first?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(tokenUsage.input == 5)
        #expect(tokenUsage.output == 3)
    }

    @Test
    func multipleToolCallsExecutedInOrder() async throws {
        let addTool = try Tool<AddParams, AddOutput, EmptyContext>(
            name: "add",
            description: "Adds numbers",
            executor: { params, _ in AddOutput(sum: params.lhs + params.rhs) }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "add"),
            .toolCallStart(index: 1, id: "call_2", name: "add"),
            .toolCallDelta(index: 0, arguments: #"{"lhs": 1, "rhs": 2}"#),
            .toolCallDelta(index: 1, arguments: #"{"lhs": 3, "rhs": 4}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]

        let secondStreamDeltas: [StreamDelta] = [
            .content("Results: 3 and 7"),
            .finished(usage: TokenUsage(input: 20, output: 10))
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [addTool])

        var events: [StreamEvent] = []
        for try await event in chat.stream("Add stuff", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompletedEvents = events.compactMap { event -> (String, String)? in
            if case let .toolCallCompleted(_, name, result) = event.kind {
                return (name, result.content)
            }
            return nil
        }

        #expect(toolCompletedEvents.count == 2)
        #expect(toolCompletedEvents[0].1.contains("3"))
        #expect(toolCompletedEvents[1].1.contains("7"))
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

private struct AddParams: Codable, SchemaProviding {
    let lhs: Int
    let rhs: Int
    static var jsonSchema: JSONSchema {
        .object(properties: ["lhs": .integer(), "rhs": .integer()], required: ["lhs", "rhs"])
    }
}

private struct AddOutput: Codable {
    let sum: Int
}

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}

private enum TestToolError: Error {
    case intentional
}

struct ChatAudioStreamingTests {
    @Test
    func audioDataAndTranscriptEventsEmitted() async throws {
        let deltas: [StreamDelta] = [
            .audioStarted(id: "audio_1", expiresAt: 1_700_000_000),
            .audioTranscript("Hello "),
            .audioTranscript("world"),
            .audioData(Data([1, 2, 3])),
            .audioData(Data([4, 5, 6])),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let chat = Chat<EmptyContext>(client: client)

        var events: [StreamEvent] = []
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.contains { $0.kind == .audioTranscript("Hello ") })
        #expect(events.contains { $0.kind == .audioTranscript("world") })
        #expect(events.contains { $0.kind == .audioData(Data([1, 2, 3])) })
        #expect(events.contains { $0.kind == .audioData(Data([4, 5, 6])) })
        #expect(events.contains { $0.kind == .audioFinished(
            id: "audio_1", expiresAt: 1_700_000_000, data: Data([1, 2, 3, 4, 5, 6])
        ) })
    }

    @Test
    func audioTranscriptUsedAsContentInHistory() async throws {
        let deltas: [StreamDelta] = [
            .audioStarted(id: "audio_1", expiresAt: 1_700_000_000),
            .audioTranscript("Spoken response"),
            .audioData(Data([1, 2])),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let chat = Chat<EmptyContext>(client: client)

        var finalHistory: [ChatMessage] = []
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            if case let .finished(_, _, _, history) = event.kind {
                finalHistory = history
            }
        }

        let assistantMessage = finalHistory.compactMap { msg -> AssistantMessage? in
            if case let .assistant(assistant) = msg { return assistant }
            return nil
        }.first
        #expect(assistantMessage?.content == "Spoken response")
    }

    @Test
    func textContentPreferredOverTranscriptInHistory() async throws {
        let deltas: [StreamDelta] = [
            .content("Text content"),
            .audioTranscript("Spoken content"),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let chat = Chat<EmptyContext>(client: client)

        var finalHistory: [ChatMessage] = []
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            if case let .finished(_, _, _, history) = event.kind {
                finalHistory = history
            }
        }

        let assistantMessage = finalHistory.compactMap { msg -> AssistantMessage? in
            if case let .assistant(assistant) = msg { return assistant }
            return nil
        }.first
        #expect(assistantMessage?.content == "Text content")
    }

    @Test
    func noAudioProducesNoAudioEvents() async throws {
        let deltas: [StreamDelta] = [
            .content("Just text"),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let chat = Chat<EmptyContext>(client: client)

        var events: [StreamEvent] = []
        for try await event in chat.stream("Hi", context: EmptyContext()) {
            events.append(event)
        }

        let audioEvents = events.filter { event in
            switch event.kind {
            case .audioData, .audioTranscript, .audioFinished: true
            default: false
            }
        }
        #expect(audioEvents.isEmpty)
    }
}

struct ChatApprovalTests {
    @Test
    func unknownToolSkipsApprovalHandler() async throws {
        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "nonexistent"),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: nil),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("Recovered"),
            .finished(usage: nil),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, approvalPolicy: .allTools)
        let counter = CountingApprovalHandler()

        var events: [StreamEvent] = []
        for try await event in chat.stream(
            "Run nonexistent",
            context: EmptyContext(),
            approvalHandler: counter.handler
        ) {
            events.append(event)
        }

        let count = await counter.requestCount
        #expect(count == 0)

        let requestedApproval = events.contains { event in
            if case .toolApprovalRequested = event.kind { return true }
            return false
        }
        #expect(!requestedApproval)

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, _, result) = event.kind {
                return result.isError && result.content.contains("does not exist")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }

    @Test
    func subAgentToolForwardsApprovalHandler() async throws {
        let childNoopTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "child_noop",
            description: "Child no-op",
            executor: { _, _ in NoopOutput() }
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "child_tool", name: "child_noop", arguments: "{}")]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "child_finish", name: "finish", arguments: #"{"content":"child done"}"#)]
            ),
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient,
            tools: [childNoopTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let delegateTool = try SubAgentTool<EchoParams, EmptyContext>(
            name: "delegate",
            description: "Delegates work",
            agent: childAgent,
            messageBuilder: { $0.message }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "delegate_call", name: "delegate"),
            .toolCallDelta(index: 0, arguments: #"{"message":"research"}"#),
            .finished(usage: nil),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("done"),
            .finished(usage: nil),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<SubAgentContext<EmptyContext>>(
            client: client,
            tools: [delegateTool],
            approvalPolicy: .allTools
        )
        let counter = CountingApprovalHandler()

        var events: [StreamEvent] = []
        let context = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await event in chat.stream("Go", context: context, approvalHandler: counter.handler) {
            events.append(event)
        }

        let requests = await counter.requests
        #expect(requests.map(\.toolName) == ["delegate", "child_noop"])

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(id, name, result) = event.kind {
                return id == "delegate_call" && name == "delegate"
                    && result.content == "child done" && !result.isError
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }

    @Test
    func subAgentApprovalPropagatesWhenParentPolicyIsNone() async throws {
        let childNoopTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
            name: "child_noop",
            description: "Child no-op",
            executor: { _, _ in NoopOutput() }
        )
        let childClient = MockLLMClient(responses: [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "child_tool", name: "child_noop", arguments: "{}")]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "child_finish", name: "finish", arguments: #"{"content":"child done"}"#)]
            ),
        ])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient,
            tools: [childNoopTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let delegateTool = try SubAgentTool<EchoParams, EmptyContext>(
            name: "delegate",
            description: "Delegates work",
            agent: childAgent,
            messageBuilder: { $0.message }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "delegate_call", name: "delegate"),
            .toolCallDelta(index: 0, arguments: #"{"message":"research"}"#),
            .finished(usage: nil),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("done"),
            .finished(usage: nil),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<SubAgentContext<EmptyContext>>(
            client: client,
            tools: [delegateTool],
            approvalPolicy: .none
        )
        let counter = CountingApprovalHandler()

        let context = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await _ in chat.stream("Go", context: context, approvalHandler: counter.handler) {}

        let requests = await counter.requests
        #expect(requests.count == 1)
        #expect(requests.first?.toolName == "child_noop")
    }
}
