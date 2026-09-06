@testable import AgentRunKit
import Foundation
import Testing

private struct ResponseAccountingScenario {
    let usages: [TokenUsage?]
    let input: Int
    let output: Int
    let reasoning: Int
    let cacheRead: Int?
    let coverage: TokenUsageCoverage
}

private let measuredResponse = TokenUsage(input: 10, output: 3, reasoning: 2, cacheRead: 5, cacheWrite: 0)
private let zeroResponse = TokenUsage(cacheRead: 0, cacheWrite: 0)
private let responseAccountingScenarios: [ResponseAccountingScenario] = [
    .init(usages: [measuredResponse, measuredResponse, measuredResponse],
          input: 30, output: 9, reasoning: 6, cacheRead: 15, coverage: .complete),
    .init(usages: [nil, measuredResponse, measuredResponse],
          input: 20, output: 6, reasoning: 4, cacheRead: 10, coverage: .partial),
    .init(usages: [measuredResponse, nil, measuredResponse],
          input: 20, output: 6, reasoning: 4, cacheRead: 10, coverage: .partial),
    .init(usages: [measuredResponse, measuredResponse, nil],
          input: 20, output: 6, reasoning: 4, cacheRead: 10, coverage: .partial),
    .init(usages: [nil, nil, nil], input: 0, output: 0, reasoning: 0, cacheRead: nil, coverage: .unavailable),
    .init(usages: [zeroResponse, zeroResponse, zeroResponse],
          input: 0, output: 0, reasoning: 0, cacheRead: 0, coverage: .complete),
]

struct AgentTests {
    @Test
    func basicCompletion() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "Done!", "reason": "success"}"#
        )
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall], tokenUsage: TokenUsage(input: 10, output: 5))
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())

        #expect(try requireContent(result) == "Done!")
        #expect(result.finishReason == .custom("success"))
        #expect(result.iterations == 1)
        #expect(result.totalTokenUsage.input == 10)
        #expect(result.totalTokenUsage.output == 5)
    }

    @Test
    func finishWithNoReasonDefaultsToCompleted() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "Result"}"#
        )
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let result = try await agent.run(userMessage: "Test", context: EmptyContext())

        #expect(result.finishReason == .completed)
    }

    @Test
    func finishWithSiblingToolThrowsBeforeExecutingAnything() async throws {
        let invocations = ToolInvocationCounter()
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in
                await invocations.increment()
                return EchoOutput(echoed: "Echo: \(params.message)")
            }
        )
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_echo", name: "echo", arguments: #"{"message": "should not run"}"#),
                ToolCall(id: "call_finish", name: "finish", arguments: #"{"content": "done"}"#)
            ])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        await #expect(throws: AgentError.malformedHistory(.finishMustBeExclusive)) {
            try await agent.run(userMessage: "Go", context: EmptyContext())
        }
        #expect(await invocations.value == 0)
    }

    @Test
    func multiTurnWithToolCalls() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let toolCall = ToolCall(
            id: "call_1",
            name: "echo",
            arguments: #"{"message": "hello"}"#
        )
        let finishCall = ToolCall(
            id: "call_2",
            name: "finish",
            arguments: #"{"content": "Completed after echo"}"#
        )

        let client = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall], tokenUsage: TokenUsage(input: 10, output: 5)),
            AssistantMessage(content: "", toolCalls: [finishCall], tokenUsage: TokenUsage(input: 20, output: 10))
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])
        let result = try await agent.run(userMessage: "Use echo", context: EmptyContext())

        #expect(try requireContent(result) == "Completed after echo")
        #expect(result.iterations == 2)
        #expect(result.totalTokenUsage.input == 30)
        #expect(result.totalTokenUsage.output == 15)

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 3)
        guard case let .tool(id, name, content) = capturedMessages[2] else {
            Issue.record("Expected tool message as third message")
            return
        }
        #expect(id == "call_1")
        #expect(name == "echo")
        #expect(content.contains("Echo: hello"))
    }

    @Test
    func multipleToolCallsInOneResponse() async throws {
        let addTool = try Tool<AddParams, AddOutput, EmptyContext>(
            name: "add",
            description: "Adds numbers",
            executor: { params, _ in AddOutput(sum: params.lhs + params.rhs) }
        )

        let call1 = ToolCall(id: "call_1", name: "add", arguments: #"{"lhs": 1, "rhs": 2}"#)
        let call2 = ToolCall(id: "call_2", name: "add", arguments: #"{"lhs": 3, "rhs": 4}"#)
        let finishCall = ToolCall(id: "call_3", name: "finish", arguments: #"{"content": "Both sums computed"}"#)

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [call1, call2]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [addTool])
        let result = try await agent.run(userMessage: "Add stuff", context: EmptyContext())

        #expect(try requireContent(result) == "Both sums computed")
        #expect(result.iterations == 2)
    }

    @Test
    func maxIterationsReached() async throws {
        let toolCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "Does nothing",
            executor: { _, _ in NoopOutput() }
        )

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [toolCall])
        ])

        let config = AgentConfiguration(maxIterations: 3)
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)
        let result = try await agent.run(userMessage: "Loop", context: EmptyContext())

        #expect(result.finishReason == .maxIterationsReached(limit: 3))
        #expect(result.content == nil)
        #expect(result.iterations == 3)
        #expect(result.history.count == 7)
        guard case .tool = result.history.last else {
            Issue.record("Expected final history entry to be a tool result")
            return
        }
    }

    @Test
    func cancellationRespected() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            executor: { _, _ in
                try await Task.sleep(for: .seconds(10))
                return NoopOutput()
            }
        )
        let toolCall = ToolCall(id: "call_1", name: "slow", arguments: "{}")
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall])
        ])
        let config = AgentConfiguration(toolTimeout: .seconds(60))
        let agent = Agent<EmptyContext>(client: client, tools: [slowTool], configuration: config)

        let task = Task {
            try await agent.run(userMessage: "Go slow", context: EmptyContext())
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
    }

    @Test
    func toolTimeoutFeedsErrorToLLM() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            executor: { _, _ in
                try await Task.sleep(for: .seconds(10))
                return NoopOutput()
            }
        )
        let toolCall = ToolCall(id: "call_1", name: "slow", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "recovered"}"#)
        let client = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let config = AgentConfiguration(toolTimeout: .milliseconds(50))
        let agent = Agent<EmptyContext>(client: client, tools: [slowTool], configuration: config)

        let result = try await agent.run(userMessage: "Timeout", context: EmptyContext())
        #expect(try requireContent(result) == "recovered")

        let capturedMessages = await client.capturedMessages
        let toolMessage = capturedMessages.compactMap { msg -> (String, String)? in
            guard case let .tool(_, name, content) = msg else { return nil }
            return (name, content)
        }.last
        #expect(toolMessage?.0 == "slow")
        #expect(toolMessage?.1.contains("timed out") == true)
        #expect(toolMessage?.1.contains("'slow'") == true)
    }

    @Test
    func perToolTimeoutOverrideRespected() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            toolTimeout: .milliseconds(50),
            executor: { _, _ in
                try await Task.sleep(for: .seconds(10))
                return NoopOutput()
            }
        )
        let toolCall = ToolCall(id: "call_1", name: "slow", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "recovered"}"#)
        let client = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(toolTimeout: .seconds(30))
        let agent = Agent<EmptyContext>(client: client, tools: [slowTool], configuration: config)

        let result = try await agent.run(userMessage: "Timeout", context: EmptyContext())
        #expect(try requireContent(result) == "recovered")

        let capturedMessages = await client.capturedMessages
        let toolMessage = capturedMessages.compactMap { msg -> (String, String)? in
            guard case let .tool(_, name, content) = msg else { return nil }
            return (name, content)
        }.last
        #expect(toolMessage?.0 == "slow")
        #expect(toolMessage?.1.contains("timed out") == true)
    }

    @Test
    func perToolTimeoutNilInheritsGlobal() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            toolTimeout: nil,
            executor: { _, _ in
                try await Task.sleep(for: .milliseconds(500))
                return NoopOutput()
            }
        )
        let toolCall = ToolCall(id: "call_1", name: "slow", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "recovered"}"#)
        let client = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(toolTimeout: .milliseconds(50))
        let agent = Agent<EmptyContext>(client: client, tools: [slowTool], configuration: config)

        let result = try await agent.run(userMessage: "Timeout", context: EmptyContext())
        #expect(try requireContent(result) == "recovered")

        let capturedMessages = await client.capturedMessages
        let toolMessage = capturedMessages.compactMap { msg -> (String, String)? in
            guard case let .tool(_, name, content) = msg else { return nil }
            return (name, content)
        }.last
        #expect(toolMessage?.0 == "slow")
        #expect(toolMessage?.1.contains("timed out") == true)
    }

    @Test
    func perToolTimeoutWiderThanGlobalCompletes() async throws {
        let quickTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "quick",
            description: "Tool with generous per-tool override",
            toolTimeout: .seconds(2),
            executor: { _, _ in
                try await Task.sleep(for: .milliseconds(100))
                return NoopOutput()
            }
        )
        let toolCall = ToolCall(id: "call_1", name: "quick", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "done"}"#)
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(toolTimeout: .milliseconds(50))
        let agent = Agent<EmptyContext>(client: client, tools: [quickTool], configuration: config)

        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")
    }

    @Test
    func systemPromptIncluded() async throws {
        let client = CapturingMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
            ])]
        )
        let config = AgentConfiguration(systemPrompt: "You are helpful.")
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        _ = try await agent.run(userMessage: "Hi", context: EmptyContext())

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
    func noSystemPromptWhenNil() async throws {
        let client = CapturingMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
            ])]
        )
        let agent = Agent<EmptyContext>(client: client, tools: [])
        _ = try await agent.run(userMessage: "Hi", context: EmptyContext())

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 1)
        guard case .user = capturedMessages[0] else {
            Issue.record("Expected user message only")
            return
        }
    }

    @Test
    func runTerminatesOnContentOnlyResponseForContentOnlyClient() async throws {
        let client = ContentOnlyTerminatingMockLLMClient(generateResponses: [
            AssistantMessage(content: "42", toolCalls: [])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        #expect(result.finishReason == .completed)
        #expect(result.content == "42")
        #expect(result.iterations == 1)

        let invocationCount = await client.invocationCount
        #expect(invocationCount == 1)
    }

    @Test
    func runEmptyContentFallsThroughToStructuralExhaustion() async throws {
        let client = ContentOnlyTerminatingMockLLMClient(generateResponses: [
            AssistantMessage(content: "", toolCalls: []),
            AssistantMessage(content: "", toolCalls: []),
            AssistantMessage(content: "", toolCalls: [])
        ])
        let config = AgentConfiguration(maxIterations: 3)
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        #expect(result.finishReason == .maxIterationsReached(limit: 3))
        #expect(result.content == nil)
    }

    @Test
    func runWhitespaceOnlyContentTerminatesForContentOnlyClient() async throws {
        let client = ContentOnlyTerminatingMockLLMClient(generateResponses: [
            AssistantMessage(content: "   ", toolCalls: [])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        #expect(result.finishReason == .completed)
        #expect(result.content == "   ")
        #expect(result.iterations == 1)
    }
}

struct AgentTokenBudgetTests {
    @Test
    func budgetExceededOnNonFinishIteration() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "No-op",
            executor: { _, _ in NoopOutput() }
        )
        let toolCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "done"}"#)
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall], tokenUsage: TokenUsage(input: 40, output: 40)),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool])
        let result = try await agent.run(userMessage: "Go", context: EmptyContext(), tokenBudget: 50)

        #expect(result.finishReason == .tokenBudgetExceeded(budget: 50, used: 80))
        #expect(result.content == nil)
        #expect(result.iterations == 1)
        #expect(result.history.count == 3)
        guard case let .tool(id, name, content) = result.history.last else {
            Issue.record("Expected final history entry to be the completed tool result")
            return
        }
        #expect(id == "call_1")
        #expect(name == "noop")
        #expect(!content.isEmpty)
    }

    @Test
    func budgetNilNoEnforcement() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "done"}"#
        )
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall], tokenUsage: TokenUsage(input: 10000, output: 10000))
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")
    }

    @Test
    func budgetWithinLimitSucceeds() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "No-op",
            executor: { _, _ in NoopOutput() }
        )
        let toolCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "done"}"#)
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall], tokenUsage: TokenUsage(input: 20, output: 20)),
            AssistantMessage(content: "", toolCalls: [finishCall], tokenUsage: TokenUsage(input: 20, output: 20))
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool])

        let result = try await agent.run(userMessage: "Go", context: EmptyContext(), tokenBudget: 100)
        #expect(try requireContent(result) == "done")
    }

    @Test
    func budgetExactlyEqualToUsageSucceeds() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "No-op",
            executor: { _, _ in NoopOutput() }
        )
        let toolCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "done"}"#)
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall], tokenUsage: TokenUsage(input: 25, output: 25)),
            AssistantMessage(content: "", toolCalls: [finishCall], tokenUsage: TokenUsage(input: 25, output: 25))
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool])

        let result = try await agent.run(userMessage: "Go", context: EmptyContext(), tokenBudget: 100)
        #expect(try requireContent(result) == "done")
    }

    @Test
    func finishReturnedEvenWhenOverBudget() async throws {
        let finishCall = ToolCall(
            id: "call_1",
            name: "finish",
            arguments: #"{"content": "completed"}"#
        )
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall], tokenUsage: TokenUsage(input: 100, output: 100))
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let result = try await agent.run(userMessage: "Go", context: EmptyContext(), tokenBudget: 50)
        #expect(try requireContent(result) == "completed")
    }
}

private struct AgentUsageAccountingTests {
    @Test(arguments: responseAccountingScenarios)
    func runAndStreamRecordEveryReturnedResponse(scenario: ResponseAccountingScenario) async throws {
        let usages = scenario.usages
        let echo = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo", description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let calls = [
            ToolCall(id: "first", name: "echo", arguments: #"{"message":"one"}"#),
            ToolCall(id: "second", name: "echo", arguments: #"{"message":"two"}"#),
            ToolCall(id: "final", name: "finish", arguments: #"{"content":"done"}"#),
        ]
        let responses = zip(calls, usages).map { call, usage in
            AssistantMessage(content: "", toolCalls: [call], tokenUsage: usage)
        }
        let sequences: [[StreamDelta]] = zip(calls, usages).map { call, usage in
            [
                .toolCallStart(index: 0, id: call.id, name: call.name, kind: .function),
                .toolCallDelta(index: 0, arguments: call.arguments),
                .finished(usage: usage),
            ]
        }
        let client = StreamingMockLLMClient(generateResponses: responses, streamSequences: sequences)
        let agent = Agent<EmptyContext>(client: client, tools: [echo])
        let result = try await agent.run(userMessage: "Echo twice", context: EmptyContext())
        var events: [StreamEvent] = []
        var samples: [TokenUsage?] = []
        for try await event in agent.stream(userMessage: "Echo twice", context: EmptyContext()) {
            events.append(event)
            if case let .iterationCompleted(usage, _, _) = event.kind {
                samples.append(usage)
            }
        }
        guard case let .finished(streamedTotals, content, reason, history) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        for totals in [result.totalTokenUsage, streamedTotals] {
            #expect(totals.input == scenario.input)
            #expect(totals.output == scenario.output)
            #expect(totals.reasoning == scenario.reasoning)
            #expect(totals.cacheRead == scenario.cacheRead)
            #expect(totals.cacheWrite == (scenario.coverage == .unavailable ? nil : 0))
            #expect(totals.coverage == scenario.coverage)
            #expect(totals.cacheReadCoverage == scenario.coverage)
            #expect(totals.cacheWriteCoverage == scenario.coverage)
        }
        #expect(samples == usages)
        #expect(result.iterations == 3)
        #expect(result.content == "done" && content == "done")
        #expect(result.finishReason == .completed && reason == .completed)
        #expect(history == result.history)
        #expect(await client.allCapturedTools.count == 6)
    }
}

struct AgentInitializerPreconditionTests {
    @Test
    func duplicateToolNamesTrap() async {
        await #expect(processExitsWith: .failure) {
            let noop = try Tool<NoopParams, NoopOutput, EmptyContext>(
                name: "noop", description: "No-op", executor: { _, _ in NoopOutput() }
            )
            _ = Agent<EmptyContext>(client: MockLLMClient(responses: []), tools: [noop, noop])
        }
    }

    @Test
    func aCompletionToolNamedLikeAnOrdinaryToolTraps() async {
        await #expect(processExitsWith: .failure) {
            let noop = try Tool<NoopParams, NoopOutput, EmptyContext>(
                name: "noop", description: "No-op", executor: { _, _ in NoopOutput() }
            )
            _ = Agent<EmptyContext>(
                client: MockLLMClient(responses: []), tools: [noop], completionTool: noop
            )
        }
    }

    @Test
    func aCompletionToolClaimingTheReservedFinishNameTraps() async {
        await #expect(processExitsWith: .failure) {
            let finish = try Tool<NoopParams, NoopOutput, EmptyContext>(
                name: "finish", description: "Finishes the run", executor: { _, _ in NoopOutput() }
            )
            _ = Agent<EmptyContext>(
                client: MockLLMClient(responses: []), tools: [], completionTool: finish
            )
        }
    }

    @Test
    func anEmptyToolNameTraps() async {
        await #expect(processExitsWith: .failure) {
            let unnamed = try Tool<NoopParams, NoopOutput, EmptyContext>(
                name: "", description: "No-op", executor: { _, _ in NoopOutput() }
            )
            _ = Agent<EmptyContext>(client: MockLLMClient(responses: []), tools: [unnamed])
        }
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

actor CapturingMockLLMClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("CapturingMockLLMClient")
    private let responses: [AssistantMessage]
    private var callIndex: Int = 0
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
            throw AgentError.llmError(.other("No more mock responses available"))
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
