@testable import AgentRunKit
import Foundation
import Testing

// MARK: - Mock

private actor CompactionMockLLMClient: LLMClient {
    let contextWindowSize: Int?
    private let responses: [AssistantMessage]
    private var callIndex: Int = 0
    private(set) var allCapturedMessages: [[ChatMessage]] = []
    private(set) var generateCallCount: Int = 0
    private let failSummarization: Bool

    init(
        responses: [AssistantMessage],
        contextWindowSize: Int? = nil,
        failSummarization: Bool = false
    ) {
        self.responses = responses
        self.contextWindowSize = contextWindowSize
        self.failSummarization = failSummarization
    }

    func generate(
        messages: [ChatMessage], tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?, requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        generateCallCount += 1
        if failSummarization, case let .user(text) = messages.last,
           text.contains("CONTEXT CHECKPOINT") {
            throw AgentError.llmError(.other("Summarization failed"))
        }
        allCapturedMessages.append(messages)
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

private actor CompactionStreamingMockLLMClient: LLMClient {
    let contextWindowSize: Int?
    private let streamSequences: [[StreamDelta]]
    private var streamIndex = 0

    init(streamSequences: [[StreamDelta]] = [], contextWindowSize: Int? = nil) {
        self.streamSequences = streamSequences
        self.contextWindowSize = contextWindowSize
    }

    func generate(
        messages _: [ChatMessage], tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?, requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        AssistantMessage(content: "Summary.", tokenUsage: TokenUsage(input: 50, output: 100))
    }

    func nextStreamSequence() -> [StreamDelta] {
        let seq = streamIndex < streamSequences.count ? streamSequences[streamIndex] : []
        streamIndex += 1
        return seq
    }

    nonisolated func stream(
        messages _: [ChatMessage], tools _: [ToolDefinition], requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for delta in await self.nextStreamSequence() {
                    continuation.yield(delta)
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Helpers

private func makeNoopTool() throws -> Tool<NoopParams, NoopOutput, EmptyContext> {
    try Tool(name: "noop", description: "No-op", executor: { _, _ in NoopOutput() })
}

private let noopCall = ToolCall(id: "call_1", name: "noop", arguments: "{}")
private let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "done"}"#)

private func hasBridge(_ messages: [ChatMessage]) -> Bool {
    messages.contains {
        if case let .user(text) = $0 { text.contains("Context Continuation") } else { false }
    }
}

private func extractToolContent(_ messages: [ChatMessage]) -> String? {
    for message in messages {
        if case let .tool(_, _, content) = message { return content }
    }
    return nil
}

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable { let echoed: String }

// MARK: - Compaction Trigger Tests

struct CompactionTriggerTests {
    @Test
    func compactionTriggersAtThreshold() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "Using tool", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 500, output: 250)
                ),
                AssistantMessage(content: "Summary.", tokenUsage: TokenUsage(input: 50, output: 100)),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 100, output: 50)
                ),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.7)
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())

        #expect(try requireContent(result) == "done")
        let allMessages = await client.allCapturedMessages
        #expect(allMessages.count == 3)
        #expect(hasBridge(allMessages[2]))
    }

    @Test
    func customCompactionPromptIsUsed() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "Using tool", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 500, output: 250)
                ),
                AssistantMessage(content: "Custom summary.", tokenUsage: TokenUsage(input: 50, output: 100)),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 100, output: 50)
                ),
            ],
            contextWindowSize: 1000
        )
        let customPrompt = "Summarize focusing only on tool results and data values."
        let config = AgentConfiguration(
            maxIterations: 5, compactionThreshold: 0.7, compactionPrompt: customPrompt
        )
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        _ = try await agent.run(userMessage: "Hello", context: EmptyContext())

        let allMessages = await client.allCapturedMessages
        let summarizationCall = allMessages[1]
        guard case let .user(promptText) = summarizationCall.last else {
            Issue.record("Expected user message as last in summarization call"); return
        }
        #expect(promptText == customPrompt)
        #expect(!promptText.contains("CONTEXT CHECKPOINT"))
    }

    @Test
    func compactionDoesNotTriggerBelowThreshold() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 100, output: 50)
                ),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 200, output: 50)
                ),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.7)
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())

        #expect(try requireContent(result) == "done")
        let allMessages = await client.allCapturedMessages
        #expect(!hasBridge(allMessages[1]))
    }

    @Test
    func compactionDisabledByDefault() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 900, output: 100)
                ),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 900, output: 100)
                ),
            ],
            contextWindowSize: 1000
        )
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()])
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())
        #expect(try requireContent(result) == "done")
    }

    @Test
    func compactionRequiresContextWindowSize() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 900, output: 100)
                ),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 900, output: 100)
                ),
            ],
            contextWindowSize: nil
        )
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.5)
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())
        #expect(try requireContent(result) == "done")
    }

    @Test
    func firstIterationNeverCompacts() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 900, output: 100)
                ),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(compactionThreshold: 0.5)
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())

        #expect(try requireContent(result) == "done")
        let allMessages = await client.allCapturedMessages
        #expect(allMessages.count == 1)
        #expect(!hasBridge(allMessages[0]))
    }
}

// MARK: - Compaction Fallback Tests

struct CompactionFallbackTests {
    @Test
    func circuitBreakerSkipsSummarizationAfterConsecutiveFailures() async throws {
        let client = CompactionMockLLMClient(
            responses: [], contextWindowSize: 1000, failSummarization: true
        )
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration(maxMessages: 20, compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "search", arguments: "{}"),
            ])),
            .tool(id: "call_1", name: "search", content: String(repeating: "x", count: 10)),
            .assistant(AssistantMessage(content: "Done")),
        ]
        var usage = TokenUsage()

        for _ in 0 ..< 3 {
            try await compactor.compactOrTruncateIfNeeded(
                &messages, lastTotalTokens: 900, totalUsage: &usage
            )
        }
        let callsAfterTripping = await client.generateCallCount
        #expect(callsAfterTripping == 3)

        try await compactor.compactOrTruncateIfNeeded(
            &messages, lastTotalTokens: 900, totalUsage: &usage
        )
        let callsAfterSkip = await client.generateCallCount
        #expect(callsAfterSkip == 3)
    }

    @Test
    func circuitBreakerResetsOnSuccess() async throws {
        var compactor = ContextCompactor(
            client: CompactionMockLLMClient(
                responses: [
                    AssistantMessage(content: "Summary.", tokenUsage: TokenUsage(input: 50, output: 100)),
                ],
                contextWindowSize: 1000, failSummarization: false
            ),
            toolDefinitions: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "Done")),
        ]
        var usage = TokenUsage()

        let result = try await compactor.compactOrTruncateIfNeeded(
            &messages, lastTotalTokens: 900, totalUsage: &usage
        )
        #expect(result == .compacted)
        #expect(hasBridge(messages))
    }

    @Test
    func circuitBreakerResetsAfterPruningSuccess() async throws {
        let client = CompactionMockLLMClient(
            responses: [], contextWindowSize: 1000, failSummarization: true
        )
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration(maxMessages: 20, compactionThreshold: 0.5)
        )
        var summarizationMessages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "search", arguments: "{}"),
            ])),
            .tool(id: "call_1", name: "search", content: String(repeating: "x", count: 10)),
            .assistant(AssistantMessage(content: "Done")),
        ]
        var pruningMessages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_2", name: "read_file", arguments: "{}"),
            ])),
            .tool(id: "call_2", name: "read_file", content: String(repeating: "x", count: 5000)),
            .assistant(AssistantMessage(content: "Done")),
        ]
        var usage = TokenUsage()

        for _ in 0 ..< 2 {
            try await compactor.compactOrTruncateIfNeeded(
                &summarizationMessages, lastTotalTokens: 900, totalUsage: &usage
            )
        }
        #expect(await client.generateCallCount == 2)

        let pruned = try await compactor.compactOrTruncateIfNeeded(
            &pruningMessages, lastTotalTokens: 900, totalUsage: &usage
        )
        #expect(pruned == .compacted)
        #expect(await client.generateCallCount == 2)

        for _ in 0 ..< 3 {
            try await compactor.compactOrTruncateIfNeeded(
                &summarizationMessages, lastTotalTokens: 900, totalUsage: &usage
            )
        }
        #expect(await client.generateCallCount == 5)

        try await compactor.compactOrTruncateIfNeeded(
            &summarizationMessages, lastTotalTokens: 900, totalUsage: &usage
        )
        #expect(await client.generateCallCount == 5)
    }

    @Test
    func compactionFallsBackToTruncationOnError() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 500, output: 250)
                ),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 100, output: 50)
                ),
            ],
            contextWindowSize: 1000, failSummarization: true
        )
        let config = AgentConfiguration(
            maxIterations: 5, maxMessages: 10, compactionThreshold: 0.7
        )
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())

        #expect(try requireContent(result) == "done")
        let allMessages = await client.allCapturedMessages
        #expect(allMessages.count == 2)
        #expect(!hasBridge(allMessages[1]))
    }
}

struct ReactiveCompactionTests {
    @Test
    func reactiveTruncationOnlySucceedsWhenHistoryShrinks() async throws {
        let client = CompactionMockLLMClient(responses: [], contextWindowSize: 1000)
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration(maxMessages: 2)
        )
        var messages: [ChatMessage] = [
            .user("one"),
            .assistant(AssistantMessage(content: "two")),
            .user("three"),
        ]
        var totalUsage = TokenUsage()
        let shrunk = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)

        #expect(shrunk == .rewritten)
        #expect(messages.count == 2)

        let unchanged = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)
        #expect(unchanged == .unchanged)
    }

    @Test
    func reactiveCompactionSkipsSummarizationWhenPruningSuffices() async throws {
        let client = CompactionMockLLMClient(
            responses: [],
            contextWindowSize: 1000,
            failSummarization: true
        )
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Earlier task"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "search", arguments: "{}"),
            ])),
            .tool(id: "call_1", name: "search", content: String(repeating: "x", count: 5000)),
            .assistant(AssistantMessage(content: "Working state")),
            .user("Continue"),
        ]
        var totalUsage = TokenUsage()
        let outcome = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)

        #expect(outcome == .rewritten)
        #expect(await client.generateCallCount == 0)
        guard case let .tool(_, _, content) = messages[2] else {
            Issue.record("Expected pruned tool message")
            return
        }
        #expect(content.contains("(pruned)"))
    }

    @Test
    func reactivePruningRequiresCompactionThreshold() async throws {
        let client = CompactionMockLLMClient(responses: [], contextWindowSize: 1000)
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration()
        )
        var messages: [ChatMessage] = [
            .user("Earlier task"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "search", arguments: "{}"),
            ])),
            .tool(id: "call_1", name: "search", content: String(repeating: "x", count: 5000)),
            .assistant(AssistantMessage(content: "Working state")),
            .user("Continue"),
        ]
        let original = messages
        var totalUsage = TokenUsage()
        let outcome = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)

        #expect(outcome == .unchanged)
        #expect(messages == original)
        #expect(await client.generateCallCount == 0)
    }

    @Test
    func reactivePruningRequiresRealLocalReduction() async throws {
        let client = CompactionMockLLMClient(responses: [], contextWindowSize: 1000)
        var compactor = ContextCompactor(
            client: client,
            toolDefinitions: [],
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Earlier task"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "extremely_verbose_tool_name", arguments: "{}"),
            ])),
            .tool(id: "call_1", name: "extremely_verbose_tool_name", content: "ok"),
            .assistant(AssistantMessage(content: "Working state")),
            .user("Continue"),
        ]
        let original = messages
        var totalUsage = TokenUsage()
        let outcome = try await compactor.reactiveCompact(&messages, totalUsage: &totalUsage)

        #expect(outcome == .unchanged)
        #expect(messages == original)
    }
}

// MARK: - Compaction Token Usage Tests

struct CompactionTokenUsageTests {
    @Test
    func compactionTokenUsageAddedToTotal() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "Using tool", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 500, output: 250)
                ),
                AssistantMessage(content: "Summary", tokenUsage: TokenUsage(input: 200, output: 300)),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 100, output: 50)
                ),
            ],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.7)
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())

        #expect(result.totalTokenUsage.input == 800)
        #expect(result.totalTokenUsage.output == 600)
    }
}

// MARK: - Compaction Context Preservation Tests

struct CompactionContextPreservationTests {
    private func compactionClient() -> CompactionMockLLMClient {
        CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "Using tool", toolCalls: [noopCall],
                    tokenUsage: TokenUsage(input: 500, output: 250)
                ),
                AssistantMessage(content: "Summary", tokenUsage: TokenUsage(input: 50, output: 100)),
                AssistantMessage(
                    content: "", toolCalls: [finishCall],
                    tokenUsage: TokenUsage(input: 100, output: 50)
                ),
            ],
            contextWindowSize: 1000
        )
    }

    @Test
    func compactionPreservesTaskContext() async throws {
        let client = compactionClient()
        let config = AgentConfiguration(
            maxIterations: 5, systemPrompt: "You are a test agent.", compactionThreshold: 0.7
        )
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        _ = try await agent.run(userMessage: "Hello", context: EmptyContext())

        let post = await client.allCapturedMessages[2]
        guard case let .system(sys) = post.first else {
            Issue.record("Expected system prompt"); return
        }
        #expect(sys == "You are a test agent.")
        guard case let .user(usr) = post[1] else {
            Issue.record("Expected user message"); return
        }
        #expect(usr == "Hello")
    }

    @Test
    func compactionPreservesRecentContext() async throws {
        let client = compactionClient()
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.7)
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        _ = try await agent.run(userMessage: "Hello", context: EmptyContext())

        let post = await client.allCapturedMessages[2]
        let hasAssistantWithNoop = post.contains {
            if case let .assistant(msg) = $0 {
                msg.toolCalls.contains { $0.name == "noop" }
            } else { false }
        }
        let hasNoopResult = post.contains {
            if case let .tool(_, name, _) = $0 { name == "noop" } else { false }
        }
        #expect(hasAssistantWithNoop)
        #expect(hasNoopResult)
    }

    @Test
    func compactionRecentContextAfterBridge() async throws {
        let client = compactionClient()
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.7)
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)
        _ = try await agent.run(userMessage: "Hello", context: EmptyContext())

        let post = await client.allCapturedMessages[2]
        let bridgeIdx = post.firstIndex {
            if case let .user(text) = $0 { text.contains("Context Continuation") } else { false }
        }
        let assistantIdx = post.lastIndex {
            if case let .assistant(msg) = $0 {
                msg.toolCalls.contains { $0.name == "noop" }
            } else { false }
        }
        guard let bridge = bridgeIdx, let asst = assistantIdx else {
            Issue.record("Expected both bridge and assistant"); return
        }
        #expect(bridge < asst)
    }

    @Test
    func compactionNoRecentContextIfNoToolResults() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(content: "Summary of work.", tokenUsage: TokenUsage(input: 50, output: 100)),
            ]
        )
        let compactor = ContextCompactor(
            client: client, toolDefinitions: [], configuration: AgentConfiguration()
        )
        let messages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "", toolCalls: [noopCall])),
            .tool(id: "call_1", name: "noop", content: "result"),
            .assistant(AssistantMessage(content: "All done.")),
        ]
        let (compacted, _) = try await compactor.summarize(messages)

        #expect(hasBridge(compacted))
        guard case let .assistant(ack) = compacted.last else {
            Issue.record("Expected acknowledgment assistant as last message"); return
        }
        #expect(ack.content == "Understood. Resuming from the checkpoint.")
    }
}

// MARK: - Observation Pruning Tests

struct ObservationPruningTests {
    private var compactor: ContextCompactor {
        ContextCompactor(
            client: CompactionMockLLMClient(responses: []),
            toolDefinitions: [], configuration: AgentConfiguration()
        )
    }

    @Test
    func observationPruningReplacesOldToolResults() {
        let messages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "read_file", arguments: "{}"),
            ])),
            .tool(id: "call_1", name: "read_file",
                  content: String(repeating: "x", count: 1000)),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_2", name: "read_file", arguments: "{}"),
            ])),
            .tool(id: "call_2", name: "read_file", content: "recent content"),
        ]
        let (pruned, ratio) = compactor.pruneObservations(messages)

        if case let .tool(_, _, content) = pruned[2] {
            #expect(content.contains("(pruned)"))
            #expect(content.contains("read_file"))
        } else { Issue.record("Expected tool message at index 2") }

        if case let .tool(_, _, content) = pruned[4] {
            #expect(content == "recent content")
        } else { Issue.record("Expected tool message at index 4") }
        #expect(ratio > 0.0)
    }

    @Test
    func observationPruningSkipsWhenInsufficient() {
        let messages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "noop", arguments: "{}"),
            ])),
            .tool(id: "call_1", name: "noop", content: "ok"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_2", name: "noop", arguments: "{}"),
            ])),
            .tool(id: "call_2", name: "noop", content: "ok"),
        ]
        #expect(compactor.pruneObservations(messages).reductionRatio < 0.2)
    }

    @Test
    func observationPruningSufficient() {
        let messages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "read_file", arguments: "{}"),
            ])),
            .tool(id: "call_1", name: "read_file",
                  content: String(repeating: "x", count: 5000)),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_2", name: "read_file", arguments: "{}"),
            ])),
            .tool(id: "call_2", name: "read_file", content: "small"),
        ]
        #expect(compactor.pruneObservations(messages).reductionRatio > 0.2)
    }

    @Test
    func observationPruningPreservesManualPruneSentinel() {
        let messages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "read_file", arguments: "{}"),
            ])),
            .tool(id: "call_1", name: "read_file", content: prunedToolResultContent),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_2", name: "read_file", arguments: "{}"),
            ])),
            .tool(id: "call_2", name: "read_file", content: "small"),
        ]
        let (pruned, ratio) = compactor.pruneObservations(messages)

        if case let .tool(_, _, content) = pruned[2] {
            #expect(content == prunedToolResultContent)
        } else {
            Issue.record("Expected tool message at index 2")
        }
        #expect(ratio == 0.0)
    }
}

// MARK: - Media Stripping Tests

struct MediaStrippingTests {
    @Test
    func summarizationStripsMediaFromMultimodalMessages() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(content: "Summary.", tokenUsage: TokenUsage(input: 50, output: 100)),
            ]
        )
        let compactor = ContextCompactor(
            client: client, toolDefinitions: [], configuration: AgentConfiguration()
        )
        let messages: [ChatMessage] = [
            .user([
                .text("Describe this"),
                .image(data: Data(repeating: 0xFF, count: 1000), mimeType: "image/png"),
                .audio(data: Data(repeating: 0xAA, count: 500), format: .mp3),
                .video(data: Data(repeating: 0xBB, count: 500), mimeType: "video/mp4"),
                .pdf(data: Data(repeating: 0xCC, count: 500)),
            ]),
            .assistant(AssistantMessage(content: "I see an image.")),
        ]
        _ = try await compactor.summarize(messages)

        let captured = await client.allCapturedMessages
        guard case let .userMultimodal(parts) = captured[0][0] else {
            Issue.record("Expected userMultimodal"); return
        }
        #expect(parts.count == 5)
        #expect(parts.allSatisfy { if case .text = $0 { true } else { false } })
        #expect(parts.contains { if case let .text(text) = $0 { text == "[image]" } else { false } })
        #expect(parts.contains { if case let .text(text) = $0 { text == "[audio]" } else { false } })
        #expect(parts.contains { if case let .text(text) = $0 { text == "[video]" } else { false } })
        #expect(parts.contains { if case let .text(text) = $0 { text == "[PDF]" } else { false } })
    }

    @Test
    func summarizationPreservesTextOnlyMessages() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(content: "Summary.", tokenUsage: TokenUsage(input: 50, output: 100)),
            ]
        )
        let compactor = ContextCompactor(
            client: client, toolDefinitions: [], configuration: AgentConfiguration()
        )
        let messages: [ChatMessage] = [
            .user("Plain text message"),
            .assistant(AssistantMessage(content: "Response")),
        ]
        _ = try await compactor.summarize(messages)

        let captured = await client.allCapturedMessages
        guard case let .user(text) = captured[0][0] else {
            Issue.record("Expected user string message"); return
        }
        #expect(text == "Plain text message")
    }
}

// MARK: - Tool Result Truncation Tests

struct ToolResultTruncationTests {
    @Test
    func toolResultMiddleOutTruncation() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo", description: "Echoes",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let longContent = String(repeating: "A", count: 50) + String(repeating: "B", count: 50)
        let echoCall = ToolCall(
            id: "call_1", name: "echo",
            arguments: #"{"message": "\#(longContent)"}"#
        )
        let client = CompactionMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [echoCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(maxIterations: 5, maxToolResultCharacters: 40)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let toolContent = await extractToolContent(client.allCapturedMessages[1])
        #expect(toolContent?.contains("truncated") == true)
    }

    @Test
    func toolResultTruncationPreservesShort() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo", description: "Echoes",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let echoCall = ToolCall(id: "call_1", name: "echo", arguments: #"{"message": "short"}"#)
        let client = CompactionMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [echoCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(maxIterations: 5, maxToolResultCharacters: 1000)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let toolContent = await extractToolContent(client.allCapturedMessages[1])
        #expect(toolContent?.contains("truncated") == false)
    }

    @Test
    func middleOutPreservesPrefixAndSuffix() {
        let content = String(repeating: "A", count: 100) + String(repeating: "M", count: 200)
            + String(repeating: "Z", count: 100)
        let config = AgentConfiguration(maxToolResultCharacters: 60)
        let truncated = ContextCompactor.truncateToolResult(content, configuration: config)
        #expect(truncated.hasPrefix(String(repeating: "A", count: 22)))
        #expect(truncated.hasSuffix(String(repeating: "Z", count: 16)))
        #expect(truncated.count <= 60)
        #expect(truncated.contains("truncated"))
    }

    @Test
    func toolResultTruncationError() async throws {
        let longError = String(repeating: "E", count: 200)
        let failingTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "failing", description: "Fails",
            executor: { _, _ in
                throw AgentError.toolExecutionFailed(tool: "failing", message: longError)
            }
        )
        let failCall = ToolCall(id: "call_1", name: "failing", arguments: "{}")
        let client = CompactionMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [failCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(maxIterations: 5, maxToolResultCharacters: 50)
        let agent = Agent<EmptyContext>(client: client, tools: [failingTool], configuration: config)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let toolContent = await extractToolContent(client.allCapturedMessages[1])
        #expect(toolContent?.contains("truncated") == true)
    }
}

// MARK: - Stream Compaction Tests

struct StreamCompactionTests {
    @Test
    func streamEmitsCompactedEvent() async throws {
        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "noop"),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 500, output: 250)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 100, output: 50)),
        ]
        let client = CompactionStreamingMockLLMClient(
            streamSequences: [firstDeltas, secondDeltas], contextWindowSize: 1000
        )
        let config = AgentConfiguration(maxIterations: 5, compactionThreshold: 0.7)
        let agent = try Agent<EmptyContext>(client: client, tools: [makeNoopTool()], configuration: config)

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Hello", context: EmptyContext()) {
            events.append(event)
        }
        #expect(events.contains {
            if case let .compacted(totalTokens, windowSize) = $0.kind {
                totalTokens == 750 && windowSize == 1000
            } else { false }
        })
    }
}
