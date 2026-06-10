@testable import AgentRunKit
import Foundation
import Testing

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
    func nonOverflowErrorSkipsRecoveryEvenWhenHistoryIsReducible() async {
        let transport = TransportError.httpError(statusCode: 429, body: "rate limited")
        let finishCall = ToolCall(
            id: "finish_1",
            name: "finish",
            arguments: #"{"content":"done"}"#
        )
        let client = RunAwareMockLLMClient(
            steps: [
                .transportError(transport),
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

        do {
            _ = try await agent.run(userMessage: "Continue", history: history, context: EmptyContext())
            Issue.record("Expected llm error")
        } catch let AgentError.llmError(error) {
            #expect(error == transport)
        } catch {
            Issue.record("Expected AgentError.llmError, got \(error)")
        }

        #expect(await client.capturedRequestModes == [.auto])
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

private enum RunAwareStep {
    case response(AssistantMessage)
    case transportError(TransportError)
}

private actor RunAwareMockLLMClient: LLMClient, HistoryRewriteAwareClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("RunAwareMockLLMClient")
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
