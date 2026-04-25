@testable import AgentRunKit
import Foundation
import Testing

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
        } catch is CancellationError {
            // Expected
        }
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

struct AgentPromptTooLongRecoveryTests {
    @Test
    func firstTurnOverflowRecoversWithoutConsumingAnExtraIteration() async throws {
        let finishCall = ToolCall(
            id: "finish_1",
            name: "finish",
            arguments: #"{"content":"done"}"#
        )
        let client = RunAwareMockLLMClient(
            steps: [
                .transportError(promptTooLongError),
                .response(AssistantMessage(content: "", toolCalls: [finishCall])),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(compactionThreshold: 0.5)
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        let history: [ChatMessage] = [
            .user("Earlier task"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "old_call", name: "search", arguments: "{}"),
            ])),
            .tool(id: "old_call", name: "search", content: String(repeating: "x", count: 5000)),
            .assistant(AssistantMessage(content: "Earlier state")),
        ]

        let result = try await agent.run(
            userMessage: "Continue",
            history: history,
            context: EmptyContext()
        )

        #expect(result.iterations == 1)
        #expect(try requireContent(result) == "done")
        #expect(await client.capturedRequestModes == [.auto, .forceFullRequest])
        let retriedMessages = await client.capturedMessages[1]
        guard case let .tool(_, _, content) = retriedMessages[2] else {
            Issue.record("Expected pruned tool message on retry")
            return
        }
        #expect(content.contains("(pruned)"))
    }

    @Test
    func laterTurnOverflowRecoversWithinTheSameIteration() async throws {
        let blobTool = try Tool<NoopParams, BlobOutput, EmptyContext>(
            name: "blob",
            description: "Returns a large result",
            executor: { _, _ in BlobOutput(blob: String(repeating: "x", count: 5000)) }
        )
        let toolCall1 = ToolCall(id: "call_1", name: "blob", arguments: "{}")
        let toolCall2 = ToolCall(id: "call_2", name: "blob", arguments: "{}")
        let finishCall = ToolCall(
            id: "finish_1",
            name: "finish",
            arguments: #"{"content":"done"}"#
        )
        let client = RunAwareMockLLMClient(
            steps: [
                .response(AssistantMessage(
                    content: "",
                    toolCalls: [toolCall1],
                    tokenUsage: TokenUsage(input: 100, output: 10)
                )),
                .response(AssistantMessage(
                    content: "",
                    toolCalls: [toolCall2],
                    tokenUsage: TokenUsage(input: 100, output: 10)
                )),
                .transportError(promptTooLongError),
                .response(AssistantMessage(content: "", toolCalls: [finishCall])),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.5)
        let agent = Agent<EmptyContext>(client: client, tools: [blobTool], configuration: config)

        let result = try await agent.run(userMessage: "Go", context: EmptyContext())

        #expect(result.iterations == 3)
        #expect(try requireContent(result) == "done")
        #expect(await client.capturedRequestModes == [.auto, .auto, .auto, .forceFullRequest])
    }

    @Test
    func secondPromptTooLongOnTheSameTurnRethrows() async {
        let client = RunAwareMockLLMClient(
            steps: [
                .transportError(promptTooLongError),
                .transportError(promptTooLongError),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(compactionThreshold: 0.5)
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        let history: [ChatMessage] = [
            .user("Earlier task"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "old_call", name: "search", arguments: "{}"),
            ])),
            .tool(id: "old_call", name: "search", content: String(repeating: "x", count: 5000)),
            .assistant(AssistantMessage(content: "Earlier state")),
        ]

        do {
            _ = try await agent.run(userMessage: "Continue", history: history, context: EmptyContext())
            Issue.record("Expected prompt-too-long error")
        } catch let AgentError.llmError(transport) {
            #expect(transport.isPromptTooLong)
        } catch {
            Issue.record("Expected AgentError.llmError, got \(error)")
        }

        #expect(await client.capturedRequestModes == [.auto, .forceFullRequest])
    }

    @Test
    func overflowWithoutLocalReductionPropagatesTheOriginalError() async {
        let client = RunAwareMockLLMClient(
            steps: [.transportError(promptTooLongError)],
            contextWindowSize: 1000
        )
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            _ = try await agent.run(userMessage: "Continue", context: EmptyContext())
            Issue.record("Expected prompt-too-long error")
        } catch let AgentError.llmError(transport) {
            #expect(transport == promptTooLongError)
        } catch {
            Issue.record("Expected AgentError.llmError, got \(error)")
        }

        #expect(await client.capturedRequestModes == [.auto])
    }

    @Test
    func otherOverflowMessageRecoversWithinRunLoop() async throws {
        let finishCall = ToolCall(
            id: "finish_1",
            name: "finish",
            arguments: #"{"content":"done"}"#
        )
        let client = RunAwareMockLLMClient(
            steps: [
                .transportError(.other(
                    "invalid_request_error: prompt is too long: 200001 tokens > 200000 maximum"
                )),
                .response(AssistantMessage(content: "", toolCalls: [finishCall])),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(compactionThreshold: 0.5)
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        let history: [ChatMessage] = [
            .user("Earlier task"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "old_call", name: "search", arguments: "{}"),
            ])),
            .tool(id: "old_call", name: "search", content: String(repeating: "x", count: 5000)),
            .assistant(AssistantMessage(content: "Earlier state")),
        ]

        let result = try await agent.run(
            userMessage: "Continue",
            history: history,
            context: EmptyContext()
        )

        #expect(result.iterations == 1)
        #expect(try requireContent(result) == "done")
        #expect(await client.capturedRequestModes == [.auto, .forceFullRequest])
    }

    @Test
    func nonOverflowErrorsStillPropagateUnchanged() async {
        let transport = TransportError.other("server_error: upstream unavailable")
        let client = RunAwareMockLLMClient(
            steps: [.transportError(transport)],
            contextWindowSize: 1000
        )
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            _ = try await agent.run(userMessage: "Continue", context: EmptyContext())
            Issue.record("Expected llm error")
        } catch let AgentError.llmError(error) {
            #expect(error == transport)
        } catch {
            Issue.record("Expected AgentError.llmError, got \(error)")
        }
    }

    @Test
    func proactiveCompactionForcesAFullRequestOnTheNextModelCall() async throws {
        let blobTool = try Tool<NoopParams, BlobOutput, EmptyContext>(
            name: "blob",
            description: "Returns a large result",
            executor: { _, _ in BlobOutput(blob: String(repeating: "x", count: 5000)) }
        )
        let blobCall = ToolCall(id: "call_1", name: "blob", arguments: "{}")
        let finishCall = ToolCall(
            id: "finish_1",
            name: "finish",
            arguments: #"{"content":"done"}"#
        )
        let client = RunAwareMockLLMClient(
            steps: [
                .response(AssistantMessage(
                    content: "",
                    toolCalls: [blobCall],
                    tokenUsage: TokenUsage(input: 900, output: 10)
                )),
                .response(AssistantMessage(
                    content: "Summary.",
                    tokenUsage: TokenUsage(input: 20, output: 5)
                )),
                .response(AssistantMessage(content: "", toolCalls: [finishCall])),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxIterations: 4, compactionThreshold: 0.5)
        let agent = Agent<EmptyContext>(client: client, tools: [blobTool], configuration: config)

        let result = try await agent.run(userMessage: "Go", context: EmptyContext())

        #expect(result.iterations == 2)
        #expect(try requireContent(result) == "done")
        #expect(await client.capturedRequestModes == [.auto, .auto, .forceFullRequest])
    }

    @Test
    func proactiveTruncationForcesAFullRequestOnTheNextModelCall() async throws {
        let finishCall = ToolCall(
            id: "finish_1",
            name: "finish",
            arguments: #"{"content":"done"}"#
        )
        let client = RunAwareMockLLMClient(
            steps: [.response(AssistantMessage(content: "", toolCalls: [finishCall]))],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxMessages: 3)
        let history: [ChatMessage] = [
            .user("one"),
            .assistant(AssistantMessage(content: "two")),
            .user("three"),
        ]
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        let result = try await agent.run(
            userMessage: "Continue",
            history: history,
            context: EmptyContext()
        )

        #expect(try requireContent(result) == "done")
        #expect(await client.capturedRequestModes == [.forceFullRequest])
        let firstCallMessages = try #require(await client.capturedMessages.first)
        #expect(firstCallMessages.count == 3)
        guard case let .user(content) = firstCallMessages.last else {
            Issue.record("Expected latest user message to be preserved after truncation")
            return
        }
        #expect(content == "Continue")
    }

    @Test
    func pruneContextRewriteForcesAFullRequestOnTheNextModelCall() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "Does nothing",
            executor: { _, _ in NoopOutput() }
        )
        let toolCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")
        let pruneCall = ToolCall(
            id: "prune_1",
            name: "prune_context",
            arguments: #"{"tool_call_ids":["call_1"]}"#
        )
        let finishCall = ToolCall(
            id: "finish_1",
            name: "finish",
            arguments: #"{"content":"done"}"#
        )
        let client = RunAwareMockLLMClient(
            steps: [
                .response(AssistantMessage(
                    content: "",
                    toolCalls: [toolCall],
                    tokenUsage: TokenUsage(input: 100, output: 10)
                )),
                .response(AssistantMessage(
                    content: "",
                    toolCalls: [pruneCall],
                    tokenUsage: TokenUsage(input: 100, output: 10)
                )),
                .response(AssistantMessage(content: "", toolCalls: [finishCall])),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(
            maxIterations: 4,
            contextBudget: ContextBudgetConfig(enablePruneTool: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)

        _ = try await agent.run(userMessage: "Go", context: EmptyContext())

        #expect(await client.capturedRequestModes == [.auto, .auto, .forceFullRequest])
        let thirdCallMessages = await client.capturedMessages[2]
        let prunedTool = thirdCallMessages.first {
            if case let .tool(id, _, _) = $0 { id == "call_1" } else { false }
        }
        guard case let .tool(_, _, content) = prunedTool else {
            Issue.record("Expected pruned tool message for call_1")
            return
        }
        #expect(content == prunedToolResultContent)
    }

    @Test
    func truncationOnlyRecoveryRetriesWithinRunLoop() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "Does nothing",
            executor: { _, _ in NoopOutput() }
        )
        let toolCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")
        let finishCall = ToolCall(
            id: "finish_1",
            name: "finish",
            arguments: #"{"content":"done"}"#
        )
        let client = RunAwareMockLLMClient(
            steps: [
                .response(AssistantMessage(
                    content: "",
                    toolCalls: [toolCall],
                    tokenUsage: TokenUsage(input: 900, output: 10)
                )),
                .response(AssistantMessage(
                    content: "Summary.",
                    tokenUsage: TokenUsage(input: 20, output: 5)
                )),
                .transportError(promptTooLongError),
                .response(AssistantMessage(content: "", toolCalls: [finishCall])),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxIterations: 3, maxMessages: 3, compactionThreshold: 0.5)
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)

        let result = try await agent.run(userMessage: "Continue", context: EmptyContext())

        #expect(result.iterations == 2)
        #expect(try requireContent(result) == "done")
        #expect(await client.capturedRequestModes == [
            .auto,
            .auto,
            .forceFullRequest,
            .forceFullRequest,
        ])
        let retriedMessages = await client.capturedMessages[3]
        #expect(retriedMessages.count == 3)
        guard case let .assistant(message) = retriedMessages[0] else {
            Issue.record("Expected truncated retry to keep the summary acknowledgment")
            return
        }
        #expect(message.content == "Understood. Resuming from the checkpoint.")
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

private struct BlobOutput: Codable {
    let blob: String
}

private let promptTooLongError = TransportError.httpError(
    statusCode: 400,
    body: #"{"error":{"message":"This model's maximum context length is 8 tokens.","code":"context_length_exceeded"}}"#
)

actor CapturingMockLLMClient: LLMClient {
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

private enum RunAwareStep {
    case response(AssistantMessage)
    case transportError(TransportError)
}

private actor RunAwareMockLLMClient: LLMClient, HistoryRewriteAwareClient {
    let contextWindowSize: Int?
    private let steps: [RunAwareStep]
    private var stepIndex = 0
    private(set) var capturedMessages: [[ChatMessage]] = []
    private(set) var capturedRequestModes: [RunRequestMode] = []

    init(steps: [RunAwareStep], contextWindowSize: Int? = nil) {
        self.steps = steps
        self.contextWindowSize = contextWindowSize
    }

    func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        try await generate(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            requestContext: requestContext,
            requestMode: .auto
        )
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?,
        requestMode: RunRequestMode
    ) async throws -> AssistantMessage {
        capturedMessages.append(messages)
        capturedRequestModes.append(requestMode)
        defer { stepIndex += 1 }
        guard stepIndex < steps.count else {
            throw AgentError.llmError(.other("No more mock steps available"))
        }
        switch steps[stepIndex] {
        case let .response(message):
            return message
        case let .transportError(error):
            throw AgentError.llmError(error)
        }
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
