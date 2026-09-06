@testable import AgentRunKit
import Foundation
import Testing

private let contentOnlyFinishDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
    .finished(usage: TokenUsage(input: 5, output: 5)),
]

struct AgentContentOnlyRunTests {
    @Test
    func runDoesNotTerminateContentOnlyResponseWithToolCalls() async throws {
        let probe = ContentOnlyToolProbe()
        let noopTool = try Tool<ContentOnlyNoopParams, ContentOnlyNoopOutput, EmptyContext>(
            name: "noop",
            description: "No-op",
            executor: { _, _ in
                await probe.record()
                return ContentOnlyNoopOutput()
            }
        )
        let client = ContentOnlyTerminatingMockLLMClient(generateResponses: [
            AssistantMessage(
                content: "partial",
                toolCalls: [ToolCall(id: "call_1", name: "noop", arguments: "{}")]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_2", name: "finish", arguments: #"{"content":"finished after tool"}"#)]
            ),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool])
        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        #expect(result.finishReason == .completed)
        #expect(result.content == "finished after tool")
        #expect(result.iterations == 2)

        let invocationCount = await client.invocationCount
        #expect(invocationCount == 2)
        #expect(await probe.invocations == 1)

        let secondTurnMessages = await client.capturedGenerateMessages[1]
        let hasNoopResult = secondTurnMessages.contains { message in
            if case let .tool(id, name, _) = message { return id == "call_1" && name == "noop" }
            return false
        }
        #expect(hasNoopResult)
    }

    @Test
    func aCustomCompletionToolSuppressesContentOnlyTermination() async throws {
        let finalize = try Tool<ContentOnlyNoopParams, ContentOnlyNoopOutput, EmptyContext>(
            name: "finalize",
            description: "Return the final answer. Call it alone.",
            executor: { _, _ in ContentOnlyNoopOutput() }
        )
        let client = ContentOnlyTerminatingMockLLMClient(generateResponses: [
            AssistantMessage(content: "The answer is 42.", toolCalls: []),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_finalize", name: "finalize", arguments: "{}")]
            ),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [], completionTool: finalize)

        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        #expect(result.finishReason == .completed)
        #expect(result.content == "{}")
        #expect(result.iterations == 2)
        #expect(await client.invocationCount == 2)
    }
}

struct AgentContentOnlyStreamTests {
    @Test(arguments: [TokenUsage(input: 3, output: 5), nil])
    func streamTerminatesOnContentOnlyIterationForContentOnlyClient(usage: TokenUsage?) async throws {
        let deltas: [StreamDelta] = [
            .content("The answer is 42."),
            .finished(usage: usage)
        ]
        let client = ContentOnlyTerminatingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Q", context: EmptyContext()) {
            events.append(event)
        }

        try #require(events.count == 3)
        #expect(events.first?.kind == .delta("The answer is 42."))
        #expect(events[1].kind == .iterationCompleted(
            usage: usage,
            iteration: 1,
            history: [
                .user("Q"),
                .assistant(AssistantMessage(content: "The answer is 42.", tokenUsage: usage)),
            ]
        ))

        guard case let .finished(tokenUsage, content, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        if let usage {
            #expect(tokenUsage == usage)
        }
        #expect(content == "The answer is 42.")
        #expect(reason == .completed)

        let invocationCount = await client.invocationCount
        #expect(invocationCount == 1)
    }

    @Test
    func streamDoesNotTerminateOnContentOnlyForRegularClient() async throws {
        let deltas: [StreamDelta] = [
            .content("still thinking"),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas, deltas, deltas])
        let config = AgentConfiguration(maxIterations: 3)
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Q", context: EmptyContext()) {
            events.append(event)
        }

        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == nil)
        #expect(reason == .maxIterationsReached(limit: 3))
    }

    @Test
    func finishToolStillFiresWhenContentOnlyClientAlsoEmitsContent() async throws {
        let deltas: [StreamDelta] = [
            .content("model text"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(
                index: 0,
                arguments: #"{"content": "finish-tool content", "reason": "completed"}"#
            ),
            .finished(usage: TokenUsage(input: 1, output: 2))
        ]
        let client = ContentOnlyTerminatingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Q", context: EmptyContext()) {
            events.append(event)
        }

        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "finish-tool content")
        #expect(reason == .completed)
    }

    @Test
    func streamDoesNotTerminateContentOnlyResponseWithToolCalls() async throws {
        let probe = ContentOnlyToolProbe()
        let noopTool = try Tool<ContentOnlyNoopParams, ContentOnlyNoopOutput, EmptyContext>(
            name: "noop",
            description: "No-op",
            executor: { _, _ in
                await probe.record()
                return ContentOnlyNoopOutput()
            }
        )
        let toolIteration: [StreamDelta] = [
            .content("partial"),
            .toolCallStart(index: 0, id: "call_1", name: "noop", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 3, output: 5)),
        ]
        let client = ContentOnlyTerminatingMockLLMClient(streamSequences: [toolIteration, contentOnlyFinishDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [noopTool])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Q", context: EmptyContext()) {
            events.append(event)
        }

        let completedTool = events.contains { event in
            if case let .toolCallCompleted(_, name, result) = event.kind {
                return name == "noop" && !result.isError && result.content == "{}"
            }
            return false
        }
        #expect(completedTool)
        #expect(await probe.invocations == 1)

        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "done")
        #expect(reason == .completed)
    }

    @Test
    func aCustomCompletionToolSuppressesContentOnlyStreamTermination() async throws {
        let finalize = try Tool<ContentOnlyNoopParams, ContentOnlyNoopOutput, EmptyContext>(
            name: "finalize",
            description: "Return the final answer. Call it alone.",
            executor: { _, _ in ContentOnlyNoopOutput() }
        )
        let contentOnlyIteration: [StreamDelta] = [
            .content("The answer is 42."),
            .finished(usage: TokenUsage(input: 3, output: 5)),
        ]
        let completionIteration: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_finalize", name: "finalize", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 4, output: 2)),
        ]
        let client = ContentOnlyTerminatingMockLLMClient(
            streamSequences: [contentOnlyIteration, completionIteration]
        )
        let agent = Agent<EmptyContext>(client: client, tools: [], completionTool: finalize)

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Q", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.contains { $0.kind == .delta("The answer is 42.") })
        #expect(await client.invocationCount == 2)

        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "{}")
        #expect(reason == .completed)
    }
}

private struct ContentOnlyNoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct ContentOnlyNoopOutput: Codable {}

private actor ContentOnlyToolProbe {
    private(set) var invocations = 0

    func record() {
        invocations += 1
    }
}
