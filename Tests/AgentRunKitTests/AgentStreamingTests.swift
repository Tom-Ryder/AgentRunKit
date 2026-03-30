@testable import AgentRunKit
import Foundation
import Testing

struct AgentStreamingTests {
    @Test
    func streamToCompletionWithFinishTool() async throws {
        let deltas: [StreamDelta] = [
            .content("Processing your request..."),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done!", "reason": "completed"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Hello", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.contains(.delta("Processing your request...")))

        guard case let .finished(tokenUsage, content, reason, history) = events.last else {
            Issue.record("Expected finished event")
            return
        }
        #expect(tokenUsage.input == 10)
        #expect(tokenUsage.output == 5)
        #expect(content == "Done!")
        #expect(reason == .completed)
        #expect(history.count == 2)
    }

    @Test
    func streamWithToolCallsEmitsStartedAndCompletedEvents() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let firstDeltas: [StreamDelta] = [
            .content("Let me help..."),
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "hello"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]

        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Echoed successfully"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10))
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Echo hello", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.contains(.delta("Let me help...")))
        #expect(events.contains(.toolCallStarted(name: "echo", id: "call_1")))

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, name, result) = event {
                return name == "echo" && result.content.contains("Echo: hello")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)

        guard case let .finished(tokenUsage, content, _, history) = events.last else {
            Issue.record("Expected finished event")
            return
        }
        #expect(tokenUsage.input == 30)
        #expect(tokenUsage.output == 15)
        #expect(content == "Echoed successfully")
        #expect(history.count == 4)
    }

    @Test
    func multipleIterationsWork() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let iteration1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "first"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]

        let iteration2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "second"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10))
        ]

        let iteration3: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_3", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "All done"}"#),
            .finished(usage: TokenUsage(input: 30, output: 15))
        ]

        let client = StreamingMockLLMClient(streamSequences: [iteration1, iteration2, iteration3])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var toolCompletedCount = 0
        for try await event in agent.stream(userMessage: "Double echo", context: EmptyContext()) {
            if case .toolCallCompleted = event {
                toolCompletedCount += 1
            }
        }

        #expect(toolCompletedCount == 2)
    }

    @Test
    func maxIterationsThrows() async throws {
        let loopingTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "loop",
            description: "Loops",
            executor: { _, _ in NoopOutput() }
        )

        let loopDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "loop"),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [loopDeltas, loopDeltas, loopDeltas])
        let config = AgentConfiguration(maxIterations: 3)
        let agent = Agent<EmptyContext>(client: client, tools: [loopingTool], configuration: config)

        do {
            for try await _ in agent.stream(userMessage: "Loop forever", context: EmptyContext()) {}
            Issue.record("Expected maxIterationsReached error")
        } catch let error as AgentError {
            guard case let .maxIterationsReached(iterations) = error else {
                Issue.record("Expected maxIterationsReached, got \(error)")
                return
            }
            #expect(iterations == 3)
        }
    }

    @Test
    func cancellationRespected() async throws {
        let client = ControllableStreamingMockLLMClient()
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let streamStarted = AsyncStream<Void>.makeStream()
        await client.setStreamStartedHandler { streamStarted.continuation.yield() }

        let collector = StreamingEventCollector()
        let task = Task {
            for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
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
    func toolErrorsFedBackToLLM() async throws {
        let failingTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "failing",
            description: "Always fails",
            executor: { _, _ in throw TestToolError.intentional }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "failing"),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: nil)
        ]

        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "recovered"}"#),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [failingTool])

        var foundErrorResult = false
        for try await event in agent.stream(userMessage: "Fail", context: EmptyContext()) {
            if case let .toolCallCompleted(_, name, result) = event {
                if name == "failing", result.isError {
                    foundErrorResult = true
                }
            }
        }

        #expect(foundErrorResult, "Tool error should be reported via toolCallCompleted event")
    }

    @Test
    func finishToolNotEmittedAsToolCallStarted() async throws {
        let deltas: [StreamDelta] = [
            .content("Here's your answer"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "The answer is 42"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "What is the answer?", context: EmptyContext()) {
            events.append(event)
        }

        let finishToolStarted = events.contains { event in
            if case let .toolCallStarted(name, _) = event {
                return name == "finish"
            }
            return false
        }
        #expect(!finishToolStarted, "finish tool should not be emitted as toolCallStarted")
    }

    @Test
    func outOfOrderDeltasBuffered() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallDelta(index: 0, arguments: #"{"mes"#),
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"sage":"buffered"}"#),
            .finished(usage: nil)
        ]

        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var toolCallCompletedEvent: StreamEvent?
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
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
        #expect(result.content.contains("Echo: buffered"))
    }

    @Test
    func systemPromptIncludedInStreamingMessages() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil)
        ]
        let client = CapturingStreamingMockLLMClient(streamSequences: [deltas])
        let config = AgentConfiguration(systemPrompt: "You are helpful.")
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        for try await _ in agent.stream(userMessage: "Hi", context: EmptyContext()) {}

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 2)
        guard case let .system(prompt) = capturedMessages[0] else {
            Issue.record("Expected system message first")
            return
        }
        #expect(prompt == "You are helpful.")
    }

    @Test
    func parallelToolsEmitCompletionEventsInCompletionOrder() async throws {
        let slowTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            executor: { params, _ in
                try await Task.sleep(for: .milliseconds(100))
                return EchoOutput(echoed: "slow: \(params.message)")
            }
        )
        let fastTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "fast",
            description: "Fast tool",
            executor: { params, _ in EchoOutput(echoed: "fast: \(params.message)") }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_slow", name: "slow"),
            .toolCallDelta(index: 0, arguments: #"{"message": "a"}"#),
            .toolCallStart(index: 1, id: "call_fast", name: "fast"),
            .toolCallDelta(index: 1, arguments: #"{"message": "b"}"#),
            .finished(usage: nil)
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_finish", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [slowTool, fastTool])

        var completedNames: [String] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case let .toolCallCompleted(_, name, _) = event {
                completedNames.append(name)
            }
        }

        #expect(completedNames.count == 2)
        #expect(completedNames[0] == "fast")
        #expect(completedNames[1] == "slow")
    }

    @Test
    func parallelToolsAppendMessagesInDispatchOrder() async throws {
        let slowTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            executor: { _, _ in
                try await Task.sleep(for: .milliseconds(100))
                return EchoOutput(echoed: "slow-result")
            }
        )
        let fastTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "fast",
            description: "Fast tool",
            executor: { _, _ in EchoOutput(echoed: "fast-result") }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "id_slow", name: "slow"),
            .toolCallDelta(index: 0, arguments: #"{"message": "a"}"#),
            .toolCallStart(index: 1, id: "id_fast", name: "fast"),
            .toolCallDelta(index: 1, arguments: #"{"message": "b"}"#),
            .finished(usage: nil)
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_finish", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [slowTool, fastTool])

        var history: [ChatMessage] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case let .finished(_, _, _, hist) = event { history = hist }
        }

        let toolMessages = history.compactMap { msg -> (name: String, content: String)? in
            guard case let .tool(_, name, content) = msg else { return nil }
            return (name, content)
        }
        #expect(toolMessages.count == 2)
        #expect(toolMessages[0].name == "slow")
        #expect(toolMessages[1].name == "fast")
    }

    @Test
    func streamingFinishSkipsSiblingTools() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_echo", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "should not run"}"#),
            .toolCallStart(index: 1, id: "call_finish", name: "finish"),
            .toolCallDelta(index: 1, arguments: #"{"content": "done"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var toolCompletedNames: [String] = []
        var finishContent: String?
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            switch event {
            case let .toolCallCompleted(_, name, _):
                toolCompletedNames.append(name)
            case let .finished(_, content, _, _):
                finishContent = content
            default:
                break
            }
        }

        #expect(toolCompletedNames.isEmpty)
        #expect(finishContent == "done")
    }
}

struct StreamingReasoningTests {
    @Test
    func reasoningDeltasEmittedAsReasoningDeltaEvents() async throws {
        let deltas: [StreamDelta] = [
            .reasoning("Let me think about this..."),
            .reasoning(" The user wants help."),
            .content("Hello!"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done"}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.contains(.reasoningDelta("Let me think about this...")))
        #expect(events.contains(.reasoningDelta(" The user wants help.")))
        #expect(events.contains(.delta("Hello!")))
    }

    @Test
    func reasoningInterleavedWithContent() async throws {
        let deltas: [StreamDelta] = [
            .reasoning("First thought"),
            .content("Partial response"),
            .reasoning("Second thought"),
            .content(" completed"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Final"}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            events.append(event)
        }

        let reasoningEvents = events.compactMap { event -> String? in
            if case let .reasoningDelta(text) = event { return text }
            return nil
        }
        let contentEvents = events.compactMap { event -> String? in
            if case let .delta(text) = event { return text }
            return nil
        }

        #expect(reasoningEvents == ["First thought", "Second thought"])
        #expect(contentEvents == ["Partial response", " completed"])
    }

    @Test
    func accumulatedReasoningIncludedInHistory() async throws {
        let deltas: [StreamDelta] = [
            .reasoning("Thinking step 1. "),
            .reasoning("Thinking step 2."),
            .content("Response"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done"}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var finalHistory: [ChatMessage] = []
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            if case let .finished(_, _, _, history) = event {
                finalHistory = history
            }
        }

        let assistantMessage = finalHistory.compactMap { msg -> AssistantMessage? in
            if case let .assistant(assistant) = msg { return assistant }
            return nil
        }.first

        #expect(assistantMessage?.reasoning?.content == "Thinking step 1. Thinking step 2.")
    }

    @Test
    func reasoningDetailsAccumulatedInHistory() async throws {
        let details: [JSONValue] = [
            .object(["type": .string("reasoning.encrypted"), "encrypted": .string("blob==")])
        ]
        let deltas: [StreamDelta] = [
            .reasoningDetails(details),
            .content("I'll search"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done"}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var finalHistory: [ChatMessage] = []
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            if case let .finished(_, _, _, history) = event {
                finalHistory = history
            }
        }

        let assistantMessage = finalHistory.compactMap { msg -> AssistantMessage? in
            if case let .assistant(assistant) = msg { return assistant }
            return nil
        }.first

        #expect(assistantMessage?.reasoningDetails?.count == 1)
        guard case let .object(obj) = assistantMessage?.reasoningDetails?.first else {
            Issue.record("Expected object in reasoning_details")
            return
        }
        #expect(obj["type"] == .string("reasoning.encrypted"))
        #expect(obj["encrypted"] == .string("blob=="))
    }

    @Test
    func reasoningTextFragmentsConsolidatedInHistory() async throws {
        let deltas: [StreamDelta] = [
            .reasoningDetails([.object([
                "type": .string("reasoning.text"),
                "text": .string(""),
                "signature": .string(""),
                "format": .string("anthropic-claude-v1"),
                "index": .int(0)
            ])]),
            .reasoningDetails([.object([
                "type": .string("reasoning.text"),
                "text": .string("Hello"),
                "format": .string("anthropic-claude-v1"),
                "index": .int(0)
            ])]),
            .reasoningDetails([.object([
                "type": .string("reasoning.text"),
                "text": .string(" world"),
                "format": .string("anthropic-claude-v1"),
                "index": .int(0)
            ])]),
            .reasoningDetails([.object([
                "type": .string("reasoning.text"),
                "signature": .string("real_sig"),
                "format": .string("anthropic-claude-v1"),
                "index": .int(0)
            ])]),
            .content("Answer"),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done"}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var finalHistory: [ChatMessage] = []
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            if case let .finished(_, _, _, history) = event {
                finalHistory = history
            }
        }

        let assistantMessage = finalHistory.compactMap { msg -> AssistantMessage? in
            if case let .assistant(assistant) = msg { return assistant }
            return nil
        }.first

        #expect(assistantMessage?.reasoningDetails?.count == 1)
        guard case let .object(obj) = assistantMessage?.reasoningDetails?.first else {
            Issue.record("Expected consolidated reasoning_details object")
            return
        }
        #expect(obj["text"] == .string("Hello world"))
        #expect(obj["signature"] == .string("real_sig"))
        #expect(obj["format"] == .string("anthropic-claude-v1"))
    }

    @Test
    func reasoningDetailsEchoedBackInSubsequentRequest() async throws {
        let details: [JSONValue] = [
            .object(["type": .string("reasoning.encrypted"), "data": .string("abc123")])
        ]
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )

        let firstDeltas: [StreamDelta] = [
            .reasoningDetails(details),
            .content("Let me search"),
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "test"}"#),
            .finished(usage: nil)
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done"}"#),
            .finished(usage: nil)
        ]

        let client = CapturingStreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        for try await _ in agent.stream(userMessage: "Hi", context: EmptyContext()) {}

        let allCalls = await client.allCapturedMessages
        #expect(allCalls.count == 2)
        let secondCallMessages = allCalls[1]

        let assistantInHistory = secondCallMessages.compactMap { msg -> AssistantMessage? in
            if case let .assistant(assistant) = msg { return assistant }
            return nil
        }.first

        #expect(assistantInHistory?.reasoningDetails?.count == 1)
        guard case let .object(obj) = assistantInHistory?.reasoningDetails?.first else {
            Issue.record("Expected reasoning_details echoed back")
            return
        }
        #expect(obj["type"] == .string("reasoning.encrypted"))
        #expect(obj["data"] == .string("abc123"))
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

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}

private enum TestToolError: Error {
    case intentional
}

struct AgentIterationCompletedTests {
    @Test
    func iterationCompletedEmittedAfterEachLLMCall() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let iteration1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "first"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let iteration2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10))
        ]

        let client = StreamingMockLLMClient(streamSequences: [iteration1, iteration2])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var iterationEvents: [(usage: TokenUsage, iteration: Int)] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case let .iterationCompleted(usage, iteration) = event {
                iterationEvents.append((usage, iteration))
            }
        }

        #expect(iterationEvents.count == 2)
        #expect(iterationEvents[0].iteration == 1)
        #expect(iterationEvents[1].iteration == 2)
    }

    @Test
    func iterationCompletedCarriesPerTurnUsage() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )

        let iteration1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "x"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let iteration2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10))
        ]

        let client = StreamingMockLLMClient(streamSequences: [iteration1, iteration2])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var iterationEvents: [(usage: TokenUsage, iteration: Int)] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case let .iterationCompleted(usage, iteration) = event {
                iterationEvents.append((usage, iteration))
            }
        }

        #expect(iterationEvents[0].usage == TokenUsage(input: 10, output: 5))
        #expect(iterationEvents[1].usage == TokenUsage(input: 20, output: 10))
    }

    @Test
    func iterationCompletedNotEmittedWhenUsageNil() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var iterationEvents: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case .iterationCompleted = event {
                iterationEvents.append(event)
            }
        }

        #expect(iterationEvents.isEmpty)
    }

    @Test
    func singleIterationEmitsOneIterationCompleted() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]

        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var iterationCount = 0
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case .iterationCompleted = event {
                iterationCount += 1
            }
        }

        #expect(iterationCount == 1)
    }
}

struct AgentStreamingTokenBudgetTests {
    @Test
    func budgetExceededDuringStreaming() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "No-op",
            executor: { _, _ in NoopOutput() }
        )
        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "noop"),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 40, output: 40))
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool])

        do {
            for try await _ in agent.stream(
                userMessage: "Go",
                context: EmptyContext(),
                tokenBudget: 50
            ) {}
            Issue.record("Expected tokenBudgetExceeded")
        } catch let error as AgentError {
            guard case let .tokenBudgetExceeded(budget, used) = error else {
                Issue.record("Expected tokenBudgetExceeded, got \(error)")
                return
            }
            #expect(budget == 50)
            #expect(used == 80)
        }
    }

    @Test
    func finishReturnedEvenWhenOverBudget() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "completed"}"#),
            .finished(usage: TokenUsage(input: 100, output: 100))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(
            userMessage: "Go",
            context: EmptyContext(),
            tokenBudget: 50
        ) {
            events.append(event)
        }

        guard case let .finished(_, content, _, _) = events.last else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "completed")
    }

    @Test
    func streamingWithNilBudgetNeverThrows() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10000, output: 10000))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            events.append(event)
        }

        guard case .finished = events.last else {
            Issue.record("Expected finished event")
            return
        }
    }
}

struct AgentAudioStreamingTests {
    @Test
    func audioEventsPassThroughAgent() async throws {
        let deltas: [StreamDelta] = [
            .audioStarted(id: "audio_1", expiresAt: 1_700_000_000),
            .audioTranscript("Response"),
            .audioData(Data([1, 2, 3])),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.contains(.audioTranscript("Response")))
        #expect(events.contains(.audioData(Data([1, 2, 3]))))
        #expect(events.contains(.audioFinished(id: "audio_1", expiresAt: 1_700_000_000, data: Data([1, 2, 3]))))
        guard case .finished = events.last else {
            Issue.record("Expected finished event")
            return
        }
    }

    @Test
    func audioTranscriptInAgentHistory() async throws {
        let deltas: [StreamDelta] = [
            .audioStarted(id: "audio_1", expiresAt: 1_700_000_000),
            .audioTranscript("Response"),
            .audioData(Data([1, 2, 3])),
            .toolCallStart(index: 0, id: "call_1", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var finalHistory: [ChatMessage] = []
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            if case let .finished(_, _, _, history) = event {
                finalHistory = history
            }
        }

        let assistantMessage = finalHistory.compactMap { msg -> AssistantMessage? in
            if case let .assistant(assistant) = msg { return assistant }
            return nil
        }.first
        #expect(assistantMessage?.content == "Response")
    }
}
