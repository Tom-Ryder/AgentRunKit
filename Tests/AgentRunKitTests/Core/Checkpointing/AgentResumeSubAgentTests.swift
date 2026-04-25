@testable import AgentRunKit
import Foundation
import Testing

private struct QueryParams: Codable, SchemaProviding {
    let query: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

private struct ThrowingTool: AnyTool, StreamableSubAgentTool {
    typealias Context = SubAgentContext<EmptyContext>
    let name = "delegate"
    let description = "Throws on resume"
    let parametersSchema: JSONSchema = .object(properties: ["query": .string()], required: ["query"])

    func execute(arguments _: Data, context _: Context) async throws -> ToolResult {
        throw AgentError.toolNotFound(name: "stale")
    }

    func executeStreaming(
        toolCallId _: String,
        arguments _: Data,
        context _: Context,
        parentSessionID _: SessionID?,
        eventHandler _: @Sendable (StreamEvent) -> Void,
        approvalHandler _: ToolApprovalHandler?
    ) async throws -> ToolResult {
        throw AgentError.toolNotFound(name: "stale")
    }
}

private struct CancellingStreamableTool: AnyTool, StreamableSubAgentTool {
    typealias Context = SubAgentContext<EmptyContext>
    let name = "delegate"
    let description = "Awaits cancellation"
    let parametersSchema: JSONSchema = .object(properties: ["query": .string()], required: ["query"])

    func execute(arguments _: Data, context _: Context) async throws -> ToolResult {
        try await Task.sleep(for: .seconds(60))
        return .error("unreachable")
    }

    func executeStreaming(
        toolCallId _: String,
        arguments _: Data,
        context _: Context,
        parentSessionID _: SessionID?,
        eventHandler _: @Sendable (StreamEvent) -> Void,
        approvalHandler _: ToolApprovalHandler?
    ) async throws -> ToolResult {
        try await Task.sleep(for: .seconds(60))
        return .error("unreachable")
    }
}

struct AgentResumeSubAgentTests {
    @Test
    func resumeDoesNotReplaySubAgentExecution() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        let assistantWithSubAgentCall = AssistantMessage(
            content: "delegating",
            toolCalls: [
                ToolCall(id: "call_sub", name: "delegate", arguments: #"{"query": "x"}"#),
            ]
        )
        let checkpoint = AgentCheckpoint(
            messages: [
                .user("Hi"),
                .assistant(assistantWithSubAgentCall),
                .tool(id: "call_sub", name: "delegate", content: "child completed"),
            ],
            iteration: 1,
            tokenUsage: TokenUsage(input: 1, output: 1),
            iterationUsage: TokenUsage(input: 1, output: 1),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        )
        try await backend.save(checkpoint)
        let childClient = StreamingMockLLMClient(streamSequences: [])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])
        let delegateTool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "delegate",
            description: "Delegate",
            agent: childAgent,
            messageBuilder: { $0.query }
        )
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: StreamingMockLLMClient(streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content": "all done"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
            ]),
            tools: [delegateTool]
        )
        let stream = try await parentAgent.resume(
            from: checkpointID, checkpointer: backend,
            context: SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        )
        var subAgentStartCount = 0
        var subAgentEventCount = 0
        var liveFinishContent: String?
        for try await event in stream {
            switch event.kind {
            case .subAgentStarted: subAgentStartCount += 1
            case .subAgentEvent: subAgentEventCount += 1
            case let .finished(_, content, _, _) where event.origin == .live:
                liveFinishContent = content
            default: break
            }
        }
        #expect(subAgentStartCount == 0)
        #expect(subAgentEventCount == 0)
        #expect(liveFinishContent == "all done")
    }

    @Test
    func resumedSubAgentFailureBecomesToolResultError() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let delegateCall: [StreamDelta] = [
            .toolCallStart(index: 0, id: "delegate_1", name: "delegate", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"query":"x"}"#),
            .finished(usage: TokenUsage(input: 3, output: 3)),
        ]
        let finishCall: [StreamDelta] = [
            .toolCallStart(index: 0, id: "finish_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"wrapped"}"#),
            .finished(usage: TokenUsage(input: 2, output: 2)),
        ]
        let agent = Agent<SubAgentContext<EmptyContext>>(
            client: StreamingMockLLMClient(streamSequences: [delegateCall, finishCall]),
            tools: [ThrowingTool()]
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend,
            context: SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        )
        var completedResults: [ToolResult] = []
        for try await event in stream {
            if case let .subAgentCompleted(_, _, result) = event.kind {
                completedResults.append(result)
            }
        }
        #expect(completedResults.count == 1)
        #expect(completedResults.first?.isError == true)
    }

    @MainActor @Test
    func subAgentStreamCancellationDoesNotEmitCompleted() async throws {
        let tool = CancellingStreamableTool()
        let parentDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_block", name: "delegate", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"query":"x"}"#),
            .finished(usage: nil),
        ]
        let parent = Agent<SubAgentContext<EmptyContext>>(
            client: StreamingMockLLMClient(streamSequences: [parentDeltas]),
            tools: [tool]
        )
        let context = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        let stream = parent.stream(userMessage: "Go", context: context)
        var observedCompletion = false
        let task = Task {
            do {
                for try await event in stream {
                    if case .subAgentCompleted = event.kind { observedCompletion = true }
                }
            } catch is CancellationError {
            } catch {
                Issue.record("Unexpected non-cancellation error: \(error)")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value
        #expect(observedCompletion == false)
    }
}
