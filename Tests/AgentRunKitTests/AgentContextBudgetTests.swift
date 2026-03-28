@testable import AgentRunKit
import Foundation
import Testing

// MARK: - Mock

private actor BudgetMockLLMClient: LLMClient {
    let contextWindowSize: Int?
    private let responses: [AssistantMessage]
    private var callIndex = 0
    private(set) var allCapturedMessages: [[ChatMessage]] = []
    private(set) var allCapturedTools: [[ToolDefinition]] = []

    init(responses: [AssistantMessage], contextWindowSize: Int? = nil) {
        self.responses = responses
        self.contextWindowSize = contextWindowSize
    }

    func generate(
        messages: [ChatMessage], tools: [ToolDefinition],
        responseFormat _: ResponseFormat?, requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        allCapturedMessages.append(messages)
        allCapturedTools.append(tools)
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage], tools _: [ToolDefinition], requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor BudgetStreamingMockLLMClient: LLMClient {
    let contextWindowSize: Int?
    private let streamSequences: [[StreamDelta]]
    private var streamIndex = 0
    private(set) var allCapturedMessages: [[ChatMessage]] = []
    private(set) var allCapturedTools: [[ToolDefinition]] = []

    init(streamSequences: [[StreamDelta]], contextWindowSize: Int? = nil) {
        self.streamSequences = streamSequences
        self.contextWindowSize = contextWindowSize
    }

    func generate(
        messages _: [ChatMessage], tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?, requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        throw AgentError.llmError(.other("Use stream() for this mock"))
    }

    func nextStreamSequence() -> [StreamDelta] {
        let seq = streamIndex < streamSequences.count ? streamSequences[streamIndex] : []
        streamIndex += 1
        return seq
    }

    func recordInvocation(messages: [ChatMessage], tools: [ToolDefinition]) {
        allCapturedMessages.append(messages)
        allCapturedTools.append(tools)
    }

    nonisolated func stream(
        messages: [ChatMessage], tools: [ToolDefinition], requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordInvocation(messages: messages, tools: tools)
                for delta in await self.nextStreamSequence() {
                    continuation.yield(delta)
                }
                continuation.finish()
            }
        }
    }
}

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}

private actor InvocationCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

// MARK: - Tool Definition Tests

struct ContextBudgetToolDefinitionTests {
    @Test func pruneToolIncludedWhenEnabled() async throws {
        let client = BudgetMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "f", name: "finish", arguments: #"{"content":"done"}"#),
            ])],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enablePruneTool: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        _ = try await agent.run(userMessage: "go", context: EmptyContext())

        let tools = await client.allCapturedTools[0]
        #expect(tools.contains { $0.name == "prune_context" })
        #expect(tools.contains { $0.name == "finish" })
    }

    @Test func pruneToolAbsentByDefault() async throws {
        let client = BudgetMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "f", name: "finish", arguments: #"{"content":"done"}"#),
            ])]
        )
        let agent = Agent<EmptyContext>(client: client, tools: [])
        _ = try await agent.run(userMessage: "go", context: EmptyContext())

        let tools = await client.allCapturedTools[0]
        #expect(!tools.contains { $0.name == "prune_context" })
    }
}

// MARK: - Prune Integration Tests

struct ContextBudgetPruneIntegrationTests {
    @Test func pruneContextReplacesToolResults() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "call_1", name: "noop", arguments: "{}"),
                ], tokenUsage: TokenUsage(input: 100, output: 10)),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "prune_1", name: "prune_context",
                             arguments: #"{"tool_call_ids":["call_1"]}"#),
                ], tokenUsage: TokenUsage(input: 200, output: 10)),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "f", name: "finish", arguments: #"{"content":"done"}"#),
                ], tokenUsage: TokenUsage(input: 150, output: 10)),
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enablePruneTool: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)
        let result = try await agent.run(userMessage: "go", context: EmptyContext())

        #expect(result.content == "done")

        let thirdCallMessages = await client.allCapturedMessages[2]
        let prunedTool = thirdCallMessages.first {
            if case let .tool(id, _, _) = $0 { id == "call_1" } else { false }
        }
        guard case let .tool(_, _, content) = prunedTool else {
            Issue.record("Expected pruned tool message for call_1")
            return
        }
        #expect(content == prunedToolResultContent)
    }

    @Test func malformedPruneArgumentsProduceErrorResult() async throws {
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "prune_1", name: "prune_context", arguments: #"{"invalid":true}"#),
                ], tokenUsage: TokenUsage(input: 100, output: 10)),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "f", name: "finish", arguments: #"{"content":"done"}"#),
                ], tokenUsage: TokenUsage(input: 150, output: 10)),
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enablePruneTool: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        let result = try await agent.run(userMessage: "go", context: EmptyContext())

        #expect(result.content == "done")
        let secondCallMessages = await client.allCapturedMessages[1]
        let errorTool = secondCallMessages.first {
            if case let .tool(id, _, _) = $0 { id == "prune_1" } else { false }
        }
        guard case let .tool(_, _, content) = errorTool else {
            Issue.record("Expected error tool message for prune_1")
            return
        }
        #expect(content.contains("prune_context failed"))
    }

    @Test func pruneContextRejectedWhenDisabled() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "call_1", name: "noop", arguments: "{}"),
                ], tokenUsage: TokenUsage(input: 100, output: 10)),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "prune_1", name: "prune_context",
                             arguments: #"{"tool_call_ids":["call_1"]}"#),
                ], tokenUsage: TokenUsage(input: 120, output: 10)),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "f", name: "finish", arguments: #"{"content":"done"}"#),
                ], tokenUsage: TokenUsage(input: 150, output: 10)),
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(contextBudget: ContextBudgetConfig())
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)
        let result = try await agent.run(userMessage: "go", context: EmptyContext())

        #expect(result.content == "done")

        let thirdCallMessages = await client.allCapturedMessages[2]
        let originalTool = thirdCallMessages.first {
            if case let .tool(id, _, _) = $0 { id == "call_1" } else { false }
        }
        guard case let .tool(_, _, originalContent) = originalTool else {
            Issue.record("Expected original tool message for call_1")
            return
        }
        #expect(originalContent != prunedToolResultContent)

        let rejectedPrune = thirdCallMessages.first {
            if case let .tool(id, _, _) = $0 { id == "prune_1" } else { false }
        }
        guard case let .tool(_, _, pruneContent) = rejectedPrune else {
            Issue.record("Expected disabled prune tool message for prune_1")
            return
        }
        #expect(pruneContent.contains("disabled"))
    }
}

// MARK: - Visibility Tests

struct ContextBudgetVisibilityIntegrationTests {
    @Test func visibilityInjectedAfterToolExecution() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "call_1", name: "noop", arguments: "{}"),
                ], tokenUsage: TokenUsage(input: 3000, output: 500)),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "f", name: "finish", arguments: #"{"content":"done"}"#),
                ], tokenUsage: TokenUsage(input: 4000, output: 200)),
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enableVisibility: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)
        _ = try await agent.run(userMessage: "go", context: EmptyContext())

        let secondCallMessages = await client.allCapturedMessages[1]
        let toolMessage = secondCallMessages.first {
            if case let .tool(id, _, _) = $0 { id == "call_1" } else { false }
        }
        guard case let .tool(_, _, content) = toolMessage else {
            Issue.record("Expected tool result for call_1")
            return
        }
        #expect(content.contains("[Token usage:"))
        #expect(!secondCallMessages.contains {
            if case let .user(userContent) = $0 { userContent.contains("[Token usage:") } else { false }
        })
    }

    @Test func visibilityAbsentWhenNotConfigured() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "call_1", name: "noop", arguments: "{}"),
                ], tokenUsage: TokenUsage(input: 3000, output: 500)),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "f", name: "finish", arguments: #"{"content":"done"}"#),
                ]),
            ]
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool])
        _ = try await agent.run(userMessage: "go", context: EmptyContext())

        let secondCallMessages = await client.allCapturedMessages[1]
        let hasVisibility = secondCallMessages.contains {
            switch $0 {
            case let .tool(_, _, content): content.contains("[Token usage:")
            case let .user(content): content.contains("[Token usage:")
            default: false
            }
        }
        #expect(!hasVisibility)
    }

    @Test func visibilityWithoutContextWindowSizeThrows() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "call_1", name: "noop", arguments: "{}"),
                ], tokenUsage: TokenUsage(input: 3000, output: 500)),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "f", name: "finish", arguments: #"{"content":"done"}"#),
                ]),
            ],
            contextWindowSize: nil
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enableVisibility: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)

        await #expect(throws: AgentError.contextBudgetWindowSizeUnavailable) {
            _ = try await agent.run(userMessage: "go", context: EmptyContext())
        }
    }
}

// MARK: - Stream Event Tests

struct ContextBudgetStreamEventTests {
    @Test func budgetUpdatedEmittedOnStream() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetStreamingMockLLMClient(
            streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_1", name: "noop"),
                    .toolCallDelta(index: 0, arguments: "{}"),
                    .finished(usage: TokenUsage(input: 3000, output: 500)),
                ],
                [
                    .toolCallStart(index: 0, id: "f", name: "finish"),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 4000, output: 200)),
                ],
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enableVisibility: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)
        var budgetEvents: [ContextBudget] = []
        for try await event in agent.stream(userMessage: "go", context: EmptyContext()) {
            if case let .budgetUpdated(budget) = event {
                budgetEvents.append(budget)
            }
        }

        #expect(!budgetEvents.isEmpty)
        #expect(budgetEvents[0].currentUsage == 3500)
        #expect(budgetEvents[0].windowSize == 10000)
    }

    @Test func budgetAdvisoryEmittedOnSoftThresholdCrossing() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetStreamingMockLLMClient(
            streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_1", name: "noop"),
                    .toolCallDelta(index: 0, arguments: "{}"),
                    .finished(usage: TokenUsage(input: 700, output: 100)),
                ],
                [
                    .toolCallStart(index: 0, id: "f", name: "finish"),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 800, output: 100)),
                ],
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(softThreshold: 0.75)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)
        var advisoryEmitted = false
        for try await event in agent.stream(userMessage: "go", context: EmptyContext()) {
            if case .budgetAdvisory = event { advisoryEmitted = true }
        }

        #expect(advisoryEmitted)
    }

    @Test func noBudgetEventsWhenUnconfigured() async throws {
        let client = BudgetStreamingMockLLMClient(
            streamSequences: [
                [
                    .toolCallStart(index: 0, id: "f", name: "finish"),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 100, output: 10)),
                ],
            ]
        )
        let agent = Agent<EmptyContext>(client: client, tools: [])
        var budgetEventCount = 0
        for try await event in agent.stream(userMessage: "go", context: EmptyContext()) {
            switch event {
            case .budgetUpdated, .budgetAdvisory: budgetEventCount += 1
            default: break
            }
        }

        #expect(budgetEventCount == 0)
    }
}

// MARK: - Zero-Cost Regression

struct ContextBudgetZeroCostTests {
    @Test func agentWithoutBudgetBehavesIdentically() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "call_1", name: "noop", arguments: "{}"),
                ], tokenUsage: TokenUsage(input: 50, output: 10)),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "f", name: "finish", arguments: #"{"content":"done"}"#),
                ], tokenUsage: TokenUsage(input: 80, output: 10)),
            ]
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool])
        let result = try await agent.run(userMessage: "go", context: EmptyContext())

        #expect(result.content == "done")
        #expect(result.iterations == 2)

        let tools = await client.allCapturedTools[0]
        #expect(!tools.contains { $0.name == "prune_context" })
    }
}

// MARK: - Streaming Prune Test

struct ContextBudgetStreamingPruneTests {
    @Test func pruneContextEmitsToolCallCompletedOnStream() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetStreamingMockLLMClient(
            streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_1", name: "noop"),
                    .toolCallDelta(index: 0, arguments: "{}"),
                    .finished(usage: TokenUsage(input: 500, output: 50)),
                ],
                [
                    .toolCallStart(index: 0, id: "prune_1", name: "prune_context"),
                    .toolCallDelta(index: 0, arguments: #"{"tool_call_ids":["call_1"]}"#),
                    .finished(usage: TokenUsage(input: 600, output: 30)),
                ],
                [
                    .toolCallStart(index: 0, id: "f", name: "finish"),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 400, output: 10)),
                ],
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enablePruneTool: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)
        var pruneCompleted = false
        for try await event in agent.stream(userMessage: "go", context: EmptyContext()) {
            if case let .toolCallCompleted(_, name, result) = event, name == "prune_context" {
                pruneCompleted = true
                #expect(result.content.contains("Pruned 1"))
            }
        }

        #expect(pruneCompleted)
    }

    @Test func pruneContextMutatesNextStreamIterationHistory() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetStreamingMockLLMClient(
            streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_1", name: "noop"),
                    .toolCallDelta(index: 0, arguments: "{}"),
                    .finished(usage: TokenUsage(input: 500, output: 50)),
                ],
                [
                    .toolCallStart(index: 0, id: "prune_1", name: "prune_context"),
                    .toolCallDelta(index: 0, arguments: #"{"tool_call_ids":["call_1"]}"#),
                    .finished(usage: TokenUsage(input: 600, output: 30)),
                ],
                [
                    .toolCallStart(index: 0, id: "f", name: "finish"),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 400, output: 10)),
                ],
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enablePruneTool: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)

        for try await _ in agent.stream(userMessage: "go", context: EmptyContext()) {}

        let thirdCallMessages = await client.allCapturedMessages[2]
        let prunedTool = thirdCallMessages.first {
            if case let .tool(id, _, _) = $0 { id == "call_1" } else { false }
        }
        guard case let .tool(_, _, content) = prunedTool else {
            Issue.record("Expected pruned tool message for call_1")
            return
        }
        #expect(content == prunedToolResultContent)
    }

    @Test func disabledPruneContextEmitsErrorOnStream() async throws {
        let client = BudgetStreamingMockLLMClient(
            streamSequences: [
                [
                    .toolCallStart(index: 0, id: "prune_1", name: "prune_context"),
                    .toolCallDelta(index: 0, arguments: #"{"tool_call_ids":["call_1"]}"#),
                    .finished(usage: TokenUsage(input: 400, output: 20)),
                ],
                [
                    .toolCallStart(index: 0, id: "f", name: "finish"),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 300, output: 10)),
                ],
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(contextBudget: ContextBudgetConfig())
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        var disabledError: ToolResult?
        for try await event in agent.stream(userMessage: "go", context: EmptyContext()) {
            if case let .toolCallCompleted(_, name, result) = event, name == "prune_context" {
                disabledError = result
            }
        }

        #expect(disabledError?.isError == true)
        #expect(disabledError?.content.contains("disabled") == true)
    }
}

// MARK: - Usage Requirements

struct ContextBudgetUsageRequirementTests {
    @Test func missingTokenUsagePreventsToolExecutionInRun() async throws {
        let counter = InvocationCounter()
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "noop",
            executor: { _, _ in
                await counter.increment()
                return NoopOutput()
            }
        )
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "call_1", name: "noop", arguments: "{}"),
                ]),
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enableVisibility: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)

        await #expect(throws: AgentError.contextBudgetUsageUnavailable) {
            _ = try await agent.run(userMessage: "go", context: EmptyContext())
        }
        #expect(await counter.currentValue() == 0)
    }

    @Test func missingTokenUsageThrowsInRun() async throws {
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "noop", executor: { _, _ in NoopOutput() }
        )
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "call_1", name: "noop", arguments: "{}"),
                ]),
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enableVisibility: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)

        await #expect(throws: AgentError.contextBudgetUsageUnavailable) {
            _ = try await agent.run(userMessage: "go", context: EmptyContext())
        }
    }

    @Test func missingTokenUsageOnFinishThrowsInRun() async throws {
        let client = BudgetMockLLMClient(
            responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#),
                ]),
            ],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enableVisibility: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        await #expect(throws: AgentError.contextBudgetUsageUnavailable) {
            _ = try await agent.run(userMessage: "go", context: EmptyContext())
        }
    }

    @Test func missingTokenUsageThrowsInStream() async throws {
        let counter = InvocationCounter()
        let noopTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop",
            description: "noop",
            executor: { _, _ in
                await counter.increment()
                return NoopOutput()
            }
        )
        let client = BudgetStreamingMockLLMClient(
            streamSequences: [[
                .toolCallStart(index: 0, id: "call_1", name: "noop"),
                .toolCallDelta(index: 0, arguments: "{}"),
                .finished(usage: nil),
            ]],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enableVisibility: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool], configuration: config)

        await #expect(throws: AgentError.contextBudgetUsageUnavailable) {
            for try await _ in agent.stream(userMessage: "go", context: EmptyContext()) {}
        }
        #expect(await counter.currentValue() == 0)
    }

    @Test func missingTokenUsageOnFinishThrowsInStream() async throws {
        let client = BudgetStreamingMockLLMClient(
            streamSequences: [[
                .toolCallStart(index: 0, id: "finish_1", name: "finish"),
                .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                .finished(usage: nil),
            ]],
            contextWindowSize: 10000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enableVisibility: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        await #expect(throws: AgentError.contextBudgetUsageUnavailable) {
            for try await _ in agent.stream(userMessage: "go", context: EmptyContext()) {}
        }
    }

    @Test func visibilityWithoutContextWindowSizeThrowsInStream() async throws {
        let client = BudgetStreamingMockLLMClient(
            streamSequences: [[
                .toolCallStart(index: 0, id: "finish_1", name: "finish"),
                .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                .finished(usage: TokenUsage(input: 3000, output: 200)),
            ]],
            contextWindowSize: nil
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(enableVisibility: true)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        await #expect(throws: AgentError.contextBudgetWindowSizeUnavailable) {
            for try await _ in agent.stream(userMessage: "go", context: EmptyContext()) {}
        }
    }
}
