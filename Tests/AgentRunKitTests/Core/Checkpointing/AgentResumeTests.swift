@testable import AgentRunKit
import Foundation
import Testing

private let secondFinishDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "live continuation"}"#),
    .finished(usage: TokenUsage(input: 7, output: 7)),
]

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private func makeEchoTool() throws -> Tool<EchoParams, EchoOutput, EmptyContext> {
    try Tool<EchoParams, EchoOutput, EmptyContext>(
        name: "echo",
        description: "Echoes input",
        executor: { params, _ in EchoOutput(echoed: params.message) }
    )
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private let terminalOutcome = AgentTerminalOutcome(
    content: #"{"summary":"shipped"}"#, toolName: "finalize"
)

private let terminalMessages: [ChatMessage] = [
    .user("Summarize"),
    .assistant(AssistantMessage(
        content: "",
        toolCalls: [ToolCall(id: "call_finalize", name: "finalize", arguments: "{}")]
    )),
    .tool(id: "call_finalize", name: "finalize", content: #"{"summary":"shipped"}"#),
]

private func makeTerminalCheckpoint(
    messages: [ChatMessage] = terminalMessages,
    iteration: Int = 1,
    tokenUsage: TokenUsage = TokenUsage(input: 9, output: 4),
    iterationUsage: TokenUsage? = TokenUsage(input: 5, output: 2),
    mcpToolBindings: Set<MCPToolBinding> = [],
    sessionID: SessionID = SessionID(),
    checkpointID: CheckpointID = CheckpointID()
) -> AgentCheckpoint {
    AgentCheckpoint(
        messages: messages,
        iteration: iteration,
        tokenUsage: tokenUsage,
        iterationUsage: iterationUsage,
        contextBudgetState: nil,
        historyWasRewrittenLocally: false,
        sessionAllowlist: [],
        sessionID: sessionID,
        runID: RunID(),
        checkpointID: checkpointID,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        mcpToolBindings: mcpToolBindings,
        terminalOutcome: terminalOutcome
    )
}

private func resumeExpectingCompletionToolMismatch(
    _ target: AgentCheckpoint,
    agent: Agent<EmptyContext>,
    tokenBudget: Int? = nil
) async {
    let backend = InMemoryCheckpointer()
    do {
        try await backend.save(target)
        _ = try await agent.resume(
            from: target.checkpointID, checkpointer: backend,
            context: EmptyContext(), tokenBudget: tokenBudget
        )
        Issue.record("Expected completionToolMismatch")
    } catch let AgentCheckpointError.completionToolMismatch(checkpointed, live) {
        #expect(checkpointed == "finalize")
        #expect(live == nil)
    } catch {
        Issue.record("Expected completionToolMismatch, got \(error)")
    }
}

struct AgentResumeTests {
    @Test
    func resumeMissingCheckpointThrowsBeforeStream() async {
        let backend = InMemoryCheckpointer()
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: []
        )
        do {
            _ = try await agent.resume(
                from: CheckpointID(), checkpointer: backend, context: EmptyContext()
            )
            Issue.record("Expected notFound")
        } catch AgentCheckpointError.notFound(_) {
        } catch {
            Issue.record("Expected notFound, got \(error)")
        }
    }

    @Test
    func resumeReplaysTargetCheckpointAsReplayed() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let runID = RunID()
        let checkpointID = CheckpointID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: runID, checkpointID: checkpointID
        )
        try await backend.save(checkpoint)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]), tools: []
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let replayed = events.filter { event in
            if case .iterationCompleted = event.kind, case .replayed = event.origin { return true }
            return false
        }
        #expect(replayed.count == 1)
        #expect(replayed.first?.origin == .replayed(from: checkpointID))
    }

    @Test
    func resumeDoesNotReplaySiblingCheckpointInSameSession() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let siblingID = CheckpointID()
        let targetID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Sibling"), .assistant(AssistantMessage(content: "sibling"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 3, output: 3),
            iterationUsage: TokenUsage(input: 3, output: 3),
            sessionID: session,
            runID: RunID(),
            checkpointID: siblingID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try await backend.save(AgentCheckpoint(
            messages: [.user("Target"), .assistant(AssistantMessage(content: "target"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session,
            runID: RunID(),
            checkpointID: targetID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_001)
        ))

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]), tools: []
        )
        let stream = try await agent.resume(
            from: targetID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let replayedOrigins = events.compactMap { event -> EventOrigin? in
            if case .iterationCompleted = event.kind, case .replayed = event.origin {
                return event.origin
            }
            return nil
        }
        #expect(replayedOrigins == [.replayed(from: targetID)])
        #expect(!replayedOrigins.contains(.replayed(from: siblingID)))
    }

    @Test
    func resumeContinuesLiveWithFreshRunIDAndSameSessionID() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let originalRun = RunID()
        let checkpointID = CheckpointID()
        let earlier = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: originalRun, checkpointID: checkpointID
        )
        try await backend.save(earlier)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]), tools: []
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let liveEvents = events.filter { $0.origin == .live }
        #expect(!liveEvents.isEmpty)
        let liveSessions = Set(liveEvents.compactMap(\.sessionID))
        let liveRuns = Set(liveEvents.compactMap(\.runID))
        #expect(liveSessions == [session])
        #expect(!liveRuns.contains(originalRun))
    }

    @Test
    func resumeAtMaxIterationsDoesNotCallClient() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        let session = SessionID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "done"))],
            iteration: 5,
            tokenUsage: TokenUsage(input: 1, output: 1),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        )
        try await backend.save(checkpoint)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []),
            tools: [],
            configuration: AgentConfiguration(maxIterations: 5)
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let finished = events.last { event in
            if case .finished = event.kind { return true }
            return false
        }
        guard case let .finished(_, _, reason, _) = finished?.kind else {
            Issue.record("Expected .finished event")
            return
        }
        #expect(reason == .maxIterationsReached(limit: 5))
    }

    @Test
    func resumeOverTokenBudgetReplaysThenFinishesWithoutClientCall() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        let session = SessionID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "done"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 100, output: 100),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        )
        try await backend.save(checkpoint)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: []
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext(), tokenBudget: 50
        )
        let events = try await collect(stream)
        let replayedIndex = events.firstIndex { event in
            if case .replayed = event.origin, case .iterationCompleted = event.kind { return true }
            return false
        }
        let finishedIndex = events.firstIndex { event in
            if case .finished = event.kind { return true }
            return false
        }
        #expect(replayedIndex != nil)
        #expect(finishedIndex != nil)
        if let replayedIndex, let finishedIndex {
            #expect(replayedIndex < finishedIndex)
        }
        guard let finishedIndex, case let .finished(_, _, reason, _) = events[finishedIndex].kind else {
            Issue.record("Expected .finished event")
            return
        }
        if case let .tokenBudgetExceeded(budget, used) = reason {
            #expect(budget == 50)
            #expect(used == 200)
        } else {
            Issue.record("Expected .tokenBudgetExceeded, got \(String(describing: reason))")
        }
    }

    @Test
    func resumeStartsAtNextIteration() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        let session = SessionID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 2,
            tokenUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        )
        try await backend.save(checkpoint)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]),
            tools: [],
            configuration: AgentConfiguration(maxIterations: 5)
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let liveIteration = events.last { event in
            if case .iterationCompleted = event.kind, case .live = event.origin { return true }
            return false
        }
        guard case let .iterationCompleted(_, iterationNumber, _) = liveIteration?.kind else {
            Issue.record("Expected a live .iterationCompleted")
            return
        }
        #expect(iterationNumber == 3)
    }

    @Test
    func resumeFirstLiveRequestForcesFullHistory() async throws {
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
        let client = RequestModeCapturingMockLLMClient(streamSequences: [secondFinishDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        _ = try await collect(stream)

        let captured = await client.capturedRequestModes
        #expect(captured.first == .forceFullRequest)
    }

    @Test
    func resumeRestoresMessagesWithoutRepeatingCompletedTool() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        let toolInvocationCount = ToolInvocationCounter()
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echo",
            executor: { params, _ in
                await toolInvocationCount.increment()
                return EchoOutput(echoed: params.message)
            }
        )
        let toolResultMessage = ChatMessage.tool(id: "call_echo", name: "echo", content: #"{"echoed":"hi"}"#)
        let assistantCall = AssistantMessage(
            content: "",
            toolCalls: [ToolCall(id: "call_echo", name: "echo", arguments: #"{"message":"hi"}"#)]
        )
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(assistantCall), toolResultMessage],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]),
            tools: [echoTool]
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        _ = try await collect(stream)
        let count = await toolInvocationCount.value
        #expect(count == 0)
    }

    @Test
    func resumeAfterApproveAlwaysDoesNotRequestApprovalAgain() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionAllowlist: ["echo"],
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let approvalRequests = ApprovalCounter()
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echo",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let secondEchoCall: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_echo_2", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"again"}"#),
            .finished(usage: TokenUsage(input: 3, output: 3)),
        ]
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondEchoCall, secondFinishDeltas]),
            tools: [echoTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext(),
            approvalHandler: { _ in
                await approvalRequests.increment()
                return .approve
            }
        )
        _ = try await collect(stream)
        let count = await approvalRequests.value
        #expect(count == 0)
    }
}

struct AgentTerminalResumeTests {
    @Test
    func terminalCheckpointIsRefusedByABuiltInFinishAgent() async {
        await resumeExpectingCompletionToolMismatch(
            makeTerminalCheckpoint(),
            agent: Agent<EmptyContext>(client: StreamingMockLLMClient(streamSequences: []), tools: [])
        )
    }

    @Test
    func terminalIdentityIsCheckedBeforeMCPBindingValidation() async {
        await resumeExpectingCompletionToolMismatch(
            makeTerminalCheckpoint(
                mcpToolBindings: [MCPToolBinding(serverName: "alpha", toolName: "search")]
            ),
            agent: Agent<EmptyContext>(client: StreamingMockLLMClient(streamSequences: []), tools: [])
        )
    }

    @Test
    func terminalIdentityIsCheckedWithoutRequiringAnApprovalHandler() async {
        await resumeExpectingCompletionToolMismatch(
            makeTerminalCheckpoint(),
            agent: Agent<EmptyContext>(
                client: StreamingMockLLMClient(streamSequences: []),
                tools: [],
                configuration: AgentConfiguration(approvalPolicy: .allTools)
            )
        )
    }

    @Test
    func terminalIdentityIsCheckedBeforeStructuralPreflight() async {
        await resumeExpectingCompletionToolMismatch(
            makeTerminalCheckpoint(iteration: 9),
            agent: Agent<EmptyContext>(
                client: StreamingMockLLMClient(streamSequences: []),
                tools: [],
                configuration: AgentConfiguration(maxIterations: 2)
            ),
            tokenBudget: 1
        )
    }

    @Test
    func malformedTerminalHistoryIsRejectedBeforeIdentityValidation() async throws {
        let backend = InMemoryCheckpointer()
        let target = makeTerminalCheckpoint(messages: [
            .user("Summarize"),
            .tool(id: "orphan", name: "finalize", content: "{}"),
        ])
        try await backend.save(target)
        let agent = Agent<EmptyContext>(client: StreamingMockLLMClient(streamSequences: []), tools: [])
        await #expect(throws: AgentError.malformedHistory(.unexpectedToolResult(id: "orphan"))) {
            _ = try await agent.resume(
                from: target.checkpointID, checkpointer: backend, context: EmptyContext()
            )
        }
    }

    @Test
    func malformedHistoryThrowsInsteadOfTrappingOnAMissingApprovalHandler() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .tool(id: "orphan", name: "echo", content: "{}")],
            iteration: 1,
            tokenUsage: TokenUsage(input: 5, output: 5),
            sessionID: SessionID(), runID: RunID(), checkpointID: checkpointID
        ))
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []),
            tools: [],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        await #expect(throws: AgentError.malformedHistory(.unexpectedToolResult(id: "orphan"))) {
            _ = try await agent.resume(
                from: checkpointID, checkpointer: backend, context: EmptyContext()
            )
        }
    }

    @Test
    func terminalReplayCommitsTheSavedOutcomeWithoutLiveWork() async throws {
        let toolInvocations = ToolInvocationCounter()
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echo",
            executor: { params, _ in
                await toolInvocations.increment()
                return EchoOutput(echoed: params.message)
            }
        )
        let client = CapturingStreamingMockLLMClient(streamSequences: [secondFinishDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])
        let target = makeTerminalCheckpoint()

        let events = try await collect(agent.replayTerminalOutcome(
            terminalOutcome, target: target,
            eventFactory: StreamEventFactory(
                sessionID: target.sessionID, runID: RunID(), origin: .live
            )
        ))

        #expect(events.count == 2)
        #expect(events.first?.origin == .replayed(from: target.checkpointID))
        guard case let .iterationCompleted(replayedUsage, iteration, replayedHistory) = events.first?.kind else {
            Issue.record("Expected a replayed .iterationCompleted")
            return
        }
        #expect(replayedUsage == TokenUsage(input: 5, output: 2))
        #expect(iteration == 1)
        #expect(replayedHistory == terminalMessages)

        #expect(events.last?.origin == .live)
        guard case let .finished(usage, content, reason, history) = events.last?.kind else {
            Issue.record("Expected a live .finished")
            return
        }
        #expect(usage == TokenUsage(input: 9, output: 4))
        #expect(content == terminalOutcome.content)
        #expect(reason == .completed)
        #expect(history == terminalMessages)

        let capturedMessages = await client.allCapturedMessages
        let invocations = await toolInvocations.value
        #expect(capturedMessages.isEmpty)
        #expect(invocations == 0)
    }

    @Test
    func terminalReplayFabricatesNoIterationEventWithoutSavedIterationUsage() async throws {
        let target = makeTerminalCheckpoint(iterationUsage: nil)
        let agent = Agent<EmptyContext>(client: StreamingMockLLMClient(streamSequences: []), tools: [])

        let events = try await collect(agent.replayTerminalOutcome(
            terminalOutcome, target: target,
            eventFactory: StreamEventFactory(
                sessionID: target.sessionID, runID: RunID(), origin: .live
            )
        ))

        #expect(events.count == 1)
        guard case let .finished(_, content, reason, _) = events.first?.kind else {
            Issue.record("Expected a live .finished")
            return
        }
        #expect(content == terminalOutcome.content)
        #expect(reason == .completed)
    }
}

private actor ApprovalCounter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}

private actor ToolInvocationCounter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}
