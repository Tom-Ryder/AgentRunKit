import Foundation
import Testing

@testable import AgentRunKit

@Suite
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
        #expect(events[0] == .delta("Hello "))
        #expect(events[1] == .delta("world!"))
        #expect(events[2] == .finished(tokenUsage: TokenUsage(input: 10, output: 5), content: nil, reason: nil))
    }

    @Test
    func streamWithToolCallAndContinuation() async throws {
        let echoTool = Tool<EchoParams, EchoOutput, EmptyContext>(
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

        #expect(events.contains(.delta("Let me ")))
        #expect(events.contains(.toolCallStarted(name: "echo", id: "call_1")))

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, name, result) = event {
                return name == "echo" && result.content.contains("Echo: hello")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)

        #expect(events.contains(.delta("The echo result was: Echo: hello")))

        guard case let .finished(tokenUsage, _, _) = events.last else {
            Issue.record("Expected finished event")
            return
        }
        #expect(tokenUsage.input == 30)
        #expect(tokenUsage.output == 15)
    }

    @Test
    func handleToolExecutionErrorGracefully() async throws {
        let failingTool = Tool<NoopParams, NoopOutput, EmptyContext>(
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
            if case let .toolCallCompleted(_, name, result) = event {
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
            if case let .toolCallCompleted(_, _, result) = event {
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

        try await Task.sleep(for: .milliseconds(10))

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

        let response = try await chat.send("Hi")

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
}

@Suite
struct ChatStreamingEdgeTests {
    @Test
    func outOfOrderDeltasBuffered() async throws {
        let echoTool = Tool<EchoParams, EchoOutput, EmptyContext>(
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
            if case .toolCallCompleted = event {
                toolCallCompletedEvent = event
            }
        }

        guard case let .toolCallCompleted(id, name, result) = toolCallCompletedEvent else {
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
        guard case let .finished(tokenUsage, _, _) = events.first else {
            Issue.record("Expected finished event")
            return
        }
        #expect(tokenUsage.input == 5)
        #expect(tokenUsage.output == 3)
    }

    @Test
    func multipleToolCallsExecutedInOrder() async throws {
        let addTool = Tool<AddParams, AddOutput, EmptyContext>(
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
            if case let .toolCallCompleted(_, name, result) = event {
                return (name, result.content)
            }
            return nil
        }

        #expect(toolCompletedEvents.count == 2)
        #expect(toolCompletedEvents[0].1.contains("3"))
        #expect(toolCompletedEvents[1].1.contains("7"))
    }
}

private struct EchoParams: Codable, SchemaProviding, Sendable {
    let message: String
    static var jsonSchema: JSONSchema { .object(properties: ["message": .string()], required: ["message"]) }
}

private struct EchoOutput: Codable, Sendable {
    let echoed: String
}

private struct AddParams: Codable, SchemaProviding, Sendable {
    let lhs: Int
    let rhs: Int
    static var jsonSchema: JSONSchema {
        .object(properties: ["lhs": .integer(), "rhs": .integer()], required: ["lhs", "rhs"])
    }
}

private struct AddOutput: Codable, Sendable {
    let sum: Int
}

private struct NoopParams: Codable, SchemaProviding, Sendable {
    static var jsonSchema: JSONSchema { .object(properties: [:], required: []) }
}

private struct NoopOutput: Codable, Sendable {}

private enum TestToolError: Error, Sendable {
    case intentional
}
