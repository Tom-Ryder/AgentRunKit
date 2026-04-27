@testable import AgentRunKit
import Foundation
import Testing

@MainActor
private func makeAgentStream(
    streamSequences: [[StreamDelta]]
) -> AgentStream<EmptyContext> {
    let client = StreamingMockLLMClient(streamSequences: streamSequences)
    let agent = Agent<EmptyContext>(client: client, tools: [])
    return AgentStream(agent: agent)
}

@MainActor
private func makeAgentStreamWithTools(
    streamSequences: [[StreamDelta]],
    tools: [any AnyTool<EmptyContext>]
) -> AgentStream<EmptyContext> {
    let client = StreamingMockLLMClient(streamSequences: streamSequences)
    let agent = Agent<EmptyContext>(client: client, tools: tools)
    return AgentStream(agent: agent)
}

@MainActor
private func awaitStreamCompletion(_ stream: AgentStream<some ToolContext>) async {
    while stream.isStreaming {
        await Task.yield()
    }
}

@MainActor
private func waitForStreamCondition(
    timeout: Duration = .seconds(1),
    condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

struct AgentStreamTests {
    @MainActor @Test
    func contentAccumulatesFromDeltas() async {
        let deltas: [StreamDelta] = [
            .content("Hello"),
            .content(" world"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeAgentStream(streamSequences: [deltas])

        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        #expect(stream.content == "Hello world")
    }

    @MainActor @Test
    func reasoningDeltaAccumulates() async {
        let deltas: [StreamDelta] = [
            .reasoning("Let me "),
            .reasoning("think"),
            .content("Answer"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeAgentStream(streamSequences: [deltas])

        stream.send("Think", context: EmptyContext())
        await awaitStreamCompletion(stream)

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
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message": "hello"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "Done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let stream = makeAgentStreamWithTools(
            streamSequences: [firstDeltas, secondDeltas],
            tools: [echoTool]
        )

        stream.send("Echo hello", context: EmptyContext())
        await awaitStreamCompletion(stream)

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
            .toolCallStart(index: 0, id: "call_1", name: "fail_tool", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message": "test"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "Failed"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let stream = makeAgentStreamWithTools(
            streamSequences: [firstDeltas, secondDeltas],
            tools: [failTool]
        )

        stream.send("Do it", context: EmptyContext())
        await awaitStreamCompletion(stream)

        let failCall = stream.toolCalls.first { $0.name == "fail_tool" }
        #expect(failCall != nil)
        if case let .failed(message) = failCall?.state {
            #expect(!message.isEmpty)
        } else {
            Issue.record("Expected failed state for fail_tool")
        }
    }

    @MainActor @Test
    func finishedSetsTokenUsageAndHistory() async {
        let deltas: [StreamDelta] = [
            .content("Result"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "All done", "reason": "completed"}"#),
            .finished(usage: TokenUsage(input: 50, output: 25)),
        ]
        let stream = makeAgentStream(streamSequences: [deltas])

        stream.send("Go", context: EmptyContext())
        await awaitStreamCompletion(stream)

        #expect(stream.tokenUsage?.input == 50)
        #expect(stream.tokenUsage?.output == 25)
        #expect(stream.finishReason == .completed)
        #expect(!stream.history.isEmpty)
    }

    @MainActor @Test
    func structuralMaxIterationsCapturedWithoutError() async throws {
        let loopTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "loop",
            description: "Loops",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let loopDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "loop", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"again"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [loopDeltas, loopDeltas])
        let agent = Agent<EmptyContext>(
            client: client,
            tools: [loopTool],
            configuration: AgentConfiguration(maxIterations: 2)
        )
        let stream = AgentStream(agent: agent)

        stream.send("Loop", context: EmptyContext())
        await awaitStreamCompletion(stream)

        #expect(stream.finishReason == .maxIterationsReached(limit: 2))
        #expect(stream.error == nil)
    }

    @MainActor @Test
    func structuralTokenBudgetCapturedWithoutError() async throws {
        let noopTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "noop",
            description: "No-op",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "noop", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"budget"}"#),
            .finished(usage: TokenUsage(input: 40, output: 40)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool])
        let stream = AgentStream(agent: agent)

        stream.send("Budget", context: EmptyContext(), tokenBudget: 50)
        await awaitStreamCompletion(stream)

        #expect(stream.finishReason == .tokenBudgetExceeded(budget: 50, used: 80))
        #expect(stream.error == nil)
    }

    @MainActor @Test
    func sendResetsState() async {
        let deltas1: [StreamDelta] = [
            .content("First"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done1"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let deltas2: [StreamDelta] = [
            .content("Second"),
            .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done2"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [deltas1, deltas2])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent)

        stream.send("First", context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.content == "First")

        stream.send("Second", context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.content == "Second")
        #expect(stream.tokenUsage?.input == 20)
    }

    @MainActor @Test
    func cancelStopsStreaming() async {
        let deltas: [StreamDelta] = [
            .content("Hello"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeAgentStream(streamSequences: [deltas])

        stream.send("Hi", context: EmptyContext())
        stream.cancel()
        await awaitStreamCompletion(stream)

        #expect(!stream.isStreaming)
        #expect(stream.content.isEmpty)
    }

    @MainActor @Test
    func errorSurfacedOnStreamFailure() async {
        let client = FailingStreamMockLLMClient()
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent)

        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        #expect(stream.error != nil)
        #expect(!stream.isStreaming)
    }

    @MainActor @Test
    func isStreamingLifecycle() async {
        let deltas: [StreamDelta] = [
            .content("Hello"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeAgentStream(streamSequences: [deltas])

        #expect(!stream.isStreaming)
        stream.send("Hi", context: EmptyContext())
        #expect(stream.isStreaming)

        await awaitStreamCompletion(stream)
        #expect(!stream.isStreaming)
    }

    @MainActor @Test
    func finishContentUsedWhenNoDeltaContent() async {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "fallback result"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeAgentStream(streamSequences: [deltas])

        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        #expect(stream.content == "fallback result")
    }

    @MainActor @Test
    func finishContentIgnoredWhenDeltaContentExists() async {
        let deltas: [StreamDelta] = [
            .content("From deltas"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "from finish"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let stream = makeAgentStream(streamSequences: [deltas])

        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        #expect(stream.content == "From deltas")
    }

    @MainActor @Test
    func iterationUsagesAccumulatedInAgentStream() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message": "hi"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let stream = makeAgentStreamWithTools(
            streamSequences: [firstDeltas, secondDeltas],
            tools: [echoTool]
        )

        stream.send("Go", context: EmptyContext())
        await awaitStreamCompletion(stream)

        #expect(stream.iterationUsages.count == 2)
        #expect(stream.iterationUsages[0] == TokenUsage(input: 10, output: 5))
        #expect(stream.iterationUsages[1] == TokenUsage(input: 20, output: 10))
    }

    @MainActor @Test
    func iterationUsagesResetOnNewSend() async {
        let deltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done1"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let deltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done2"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [deltas1, deltas2])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent)

        stream.send("First", context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.iterationUsages.count == 1)

        stream.send("Second", context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.iterationUsages.count == 1)
        #expect(stream.iterationUsages[0] == TokenUsage(input: 20, output: 10))
    }

    @MainActor @Test
    func contextBudgetUpdatedFromBudgetEvents() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"hi"}"#),
            .finished(usage: TokenUsage(input: 700, output: 100)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "finish_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 10)),
        ]
        let client = StreamingMockLLMClient(
            streamSequences: [firstDeltas, secondDeltas],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(softThreshold: 0.75)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let stream = AgentStream(agent: agent)

        stream.send("Budget", context: EmptyContext())
        await awaitStreamCompletion(stream)

        #expect(stream.contextBudget == ContextBudget(
            windowSize: 1000,
            currentUsage: 800,
            softThreshold: 0.75
        ))
    }

    @MainActor @Test
    func contextBudgetResetsOnNewSend() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"hi"}"#),
            .finished(usage: TokenUsage(input: 700, output: 100)),
        ]
        let firstFinishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "finish_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done1"}"#),
            .finished(usage: TokenUsage(input: 10, output: 10)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"again"}"#),
            .finished(usage: TokenUsage(input: 200, output: 100)),
        ]
        let secondFinishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "finish_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done2"}"#),
            .finished(usage: TokenUsage(input: 200, output: 100)),
        ]
        let client = StreamingMockLLMClient(
            streamSequences: [firstDeltas, firstFinishDeltas, secondDeltas, secondFinishDeltas],
            contextWindowSize: 1000
        )
        let config = AgentConfiguration(
            contextBudget: ContextBudgetConfig(softThreshold: 0.75)
        )
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let stream = AgentStream(agent: agent)

        stream.send("First", context: EmptyContext())
        await awaitStreamCompletion(stream)
        #expect(stream.contextBudget?.currentUsage == 800)

        stream.send("Second", context: EmptyContext())
        #expect(stream.contextBudget == nil)
        await awaitStreamCompletion(stream)
        #expect(stream.contextBudget?.currentUsage == 300)
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

private actor FailingStreamMockLLMClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("FailingStreamMockLLMClient")
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

@MainActor
struct AgentStreamApprovalTests {
    @MainActor @Test
    func toolCallTransitionsThroughAwaitingApproval() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"hello"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let stream = AgentStream(agent: agent)
        let handler = BlockingApprovalHandler()

        stream.send("Echo hello", context: EmptyContext(), approvalHandler: handler.handler)

        let sawAwaitingApproval = await waitForStreamCondition {
            if let echoCall = stream.toolCalls.first(where: { $0.name == "echo" }),
               case .awaitingApproval = echoCall.state {
                return true
            }
            return false
        }

        await handler.resume()
        await awaitStreamCompletion(stream)

        #expect(sawAwaitingApproval)

        let requestCount = await handler.requestCount
        #expect(requestCount == 1)

        let echoCall = try #require(stream.toolCalls.first(where: { $0.name == "echo" }))
        if case let .completed(result) = echoCall.state {
            #expect(result.contains("Echo: hello"))
        } else {
            Issue.record("Expected completed state for echo tool")
        }
    }

    @MainActor @Test
    func nestedApprovalAppearsInToolCalls() async throws {
        let childEchoTool = try Tool<EchoParams, EchoOutput, SubAgentContext<EmptyContext>>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )
        let childDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_call", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"child"}"#),
            .finished(usage: nil),
        ]
        let childDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"child done"}"#),
            .finished(usage: nil),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas1, childDeltas2])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient,
            tools: [childEchoTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let delegateTool = try SubAgentTool<EchoParams, EmptyContext>(
            name: "delegate",
            description: "Delegates work",
            agent: childAgent,
            messageBuilder: { $0.message }
        )
        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "delegate_call", name: "delegate", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"go"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "parent_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"parent done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [delegateTool])
        let stream = AgentStream(agent: parentAgent)
        let handler = BlockingApprovalHandler()

        stream.send(
            "Go",
            context: SubAgentContext(inner: EmptyContext(), maxDepth: 3),
            approvalHandler: handler.handler
        )

        let sawNestedAwaitingApproval = await waitForStreamCondition {
            if let nestedCall = stream.toolCalls.first(where: { $0.name == "delegate > echo" }),
               case .awaitingApproval = nestedCall.state {
                return true
            }
            return false
        }
        #expect(sawNestedAwaitingApproval)

        await handler.resume()
        await awaitStreamCompletion(stream)

        let nestedCall = try #require(stream.toolCalls.first(where: { $0.name == "delegate > echo" }))
        if case let .completed(result) = nestedCall.state {
            #expect(result.contains("Echo: child"))
        } else {
            Issue.record("Expected completed state for nested approval call")
        }
    }
}
