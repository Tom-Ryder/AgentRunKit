@testable import AgentRunKit
import Foundation
import Testing

private func finalizeDeltas(
    id: String = "call_finalize",
    summary: String,
    usage: TokenUsage? = nil
) -> [StreamDelta] {
    [
        .toolCallStart(index: 0, id: id, name: "finalize", kind: .function),
        .toolCallDelta(index: 0, arguments: #"{"summary": "\#(summary)"}"#),
        .finished(usage: usage),
    ]
}

private let lookupBesideFinalizeDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_lookup", name: "lookup", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"query": "spec"}"#),
    .toolCallStart(index: 1, id: "call_finalize_1", name: "finalize", kind: .function),
    .toolCallDelta(index: 1, arguments: #"{"summary": "early"}"#),
    .finished(usage: nil),
]

private let lookupDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_lookup", name: "lookup", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"query": "spec"}"#),
    .finished(usage: nil),
]

private let pruneBesideFinalizeDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_prune", name: "prune_context", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"tool_call_ids":["call_lookup"]}"#),
    .toolCallStart(index: 1, id: "call_finalize_1", name: "finalize", kind: .function),
    .toolCallDelta(index: 1, arguments: #"{"summary": "early"}"#),
    .finished(usage: nil),
]

private let hallucinatedFinishDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
    .finished(usage: nil),
]

private func makeAgent(
    streamSequences: [[StreamDelta]],
    tools: [any AnyTool<ReportContext>] = [],
    completionTool: any AnyTool<ReportContext>,
    contextWindowSize: Int? = nil,
    configuration: AgentConfiguration = AgentConfiguration()
) -> Agent<ReportContext> {
    Agent<ReportContext>(
        client: StreamingMockLLMClient(
            streamSequences: streamSequences, contextWindowSize: contextWindowSize
        ),
        tools: tools,
        completionTool: completionTool,
        configuration: configuration
    )
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private func completedToolResults(_ events: [StreamEvent], name: String) -> [ToolResult] {
    events.compactMap { event in
        guard case let .toolCallCompleted(_, completedName, result) = event.kind, completedName == name else {
            return nil
        }
        return result
    }
}

private func isFinished(_ event: StreamEvent) -> Bool {
    if case .finished = event.kind { return true }
    return false
}

private func startedToolCallIDs(_ events: [StreamEvent]) -> [String] {
    events.compactMap { event in
        guard case let .toolCallStarted(_, id) = event.kind else { return nil }
        return id
    }
}

private func completedToolCallIDs(_ events: [StreamEvent]) -> [String] {
    events.compactMap { event in
        guard case let .toolCallCompleted(id, _, _) = event.kind else { return nil }
        return id
    }
}

private func awaitCollected(
    _ collector: StreamingEventCollector,
    where predicate: @Sendable @escaping (StreamEvent) -> Bool
) async {
    while await !collector.events.contains(where: predicate) {
        await Task.yield()
    }
}

@MainActor
private func awaitStreamCompletion(_ stream: AgentStream<some ToolContext>) async {
    while stream.isStreaming {
        await Task.yield()
    }
}

private actor EventSnapshot {
    private(set) var events: [StreamEvent] = []

    func capture(_ events: [StreamEvent]) {
        self.events = events
    }
}

private actor FailingSaveCheckpointer: AgentCheckpointer {
    private(set) var saveCount = 0

    func save(_: AgentCheckpoint) async throws {
        saveCount += 1
        throw CustomCompletionTestError.checkpointStorageUnavailable
    }

    func load(_ id: CheckpointID) async throws -> AgentCheckpoint {
        throw AgentCheckpointError.notFound(id)
    }

    func list(session _: SessionID) async throws -> [CheckpointID] {
        []
    }
}

struct CustomCompletionStreamTests {
    @Test
    func theCompletionToolStreamsAsAnOrdinaryCallAndCommitsItsExactResult() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [finalizeDeltas(summary: "all done", usage: TokenUsage(input: 12, output: 4))],
            completionTool: finalize
        )

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(events.contains { $0.kind == .toolCallStarted(name: "finalize", id: "call_finalize") })
        #expect(completedToolResults(events, name: "finalize") == [.success(expected)])
        #expect(await invocations.value == 1)

        guard case let .finished(usage, content, reason, history) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(usage == TokenUsage(input: 12, output: 4))
        #expect(content == expected)
        #expect(reason == .completed)
        #expect(history.count == 3)
        #expect(toolMessageContents(history) == [expected])
    }

    @Test
    func theTerminalCheckpointIsSavedBeforeTheCommittedFinish() async throws {
        let session = SessionID()
        let collector = StreamingEventCollector()
        let eventsAtSave = EventSnapshot()
        let gate = GatedCheckpointer(gating: .save, onGateEntered: {
            await eventsAtSave.capture(collector.events)
        })
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [finalizeDeltas(summary: "all done", usage: TokenUsage(input: 12, output: 4))],
            completionTool: finalize
        )
        let consumer = Task {
            for try await event in agent.stream(
                userMessage: "Summarize", context: ReportContext(documentID: "doc-1"),
                sessionID: session, checkpointer: gate
            ) {
                await collector.append(event)
            }
        }

        await gate.awaitGateEntered()
        await gate.release()
        try await consumer.value

        #expect(await !eventsAtSave.events.contains(where: isFinished))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        let events = await collector.events
        guard case let .finished(_, content, reason, history) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(content == expected)
        #expect(reason == .completed)

        let saved = await gate.saved
        #expect(saved.count == 1)
        let checkpoint = try #require(saved.first)
        #expect(checkpoint.terminalOutcome == AgentTerminalOutcome(content: expected, toolName: "finalize"))
        #expect(checkpoint.messages == history)
        #expect(toolMessageContents(checkpoint.messages) == [expected])
        #expect(checkpoint.iteration == 1)
        #expect(checkpoint.tokenUsage == TokenUsage(input: 12, output: 4))
        #expect(checkpoint.sessionID == session)
    }

    @Test
    func aFailedTerminalSaveSuppressesTheCommittedFinish() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let checkpointer = FailingSaveCheckpointer()
        let agent = makeAgent(
            streamSequences: [finalizeDeltas(summary: "all done", usage: TokenUsage(input: 12, output: 4))],
            completionTool: finalize
        )

        var events: [StreamEvent] = []
        do {
            for try await event in agent.stream(
                userMessage: "Summarize", context: ReportContext(documentID: "doc-1"),
                checkpointer: checkpointer
            ) {
                events.append(event)
            }
            Issue.record("Expected the terminal save failure to surface")
        } catch CustomCompletionTestError.checkpointStorageUnavailable {
        } catch {
            Issue.record("Expected checkpointStorageUnavailable, got \(error)")
        }

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(completedToolResults(events, name: "finalize") == [.success(expected)])
        #expect(!events.contains(where: isFinished))
        #expect(await invocations.value == 1)
        #expect(await checkpointer.saveCount == 1)
    }

    @Test
    func aThrowingCompletionToolFeedsBackAndCommitsOnTheNextTurn() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            guard params.summary != "draft" else { throw CustomCompletionTestError.draftRejected }
            return report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [
                finalizeDeltas(id: "call_finalize_1", summary: "draft"),
                finalizeDeltas(id: "call_finalize_2", summary: "final"),
            ],
            completionTool: finalize
        )

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let expected = try encodedReport(documentID: "doc-1", summary: "final")
        let results = completedToolResults(events, name: "finalize")
        #expect(results.count == 2)
        #expect(results.first?.isError == true)
        #expect(results.last == .success(expected))
        #expect(await invocations.value == 2)

        guard case let .finished(_, content, reason, history) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(content == expected)
        #expect(reason == .completed)
        #expect(toolMessageContents(history).last == expected)
    }

    @Test
    func aTimedOutCompletionToolFeedsBackAndTheStreamContinues() async throws {
        let finalize = try makeFinalizeTool { params, context in
            if params.summary == "slow" {
                try await Task.sleep(for: .seconds(10))
            }
            return report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [
                finalizeDeltas(id: "call_finalize_1", summary: "slow"),
                finalizeDeltas(id: "call_finalize_2", summary: "quick"),
            ],
            completionTool: finalize,
            configuration: AgentConfiguration(toolTimeout: .milliseconds(50))
        )

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let results = completedToolResults(events, name: "finalize")
        #expect(results.count == 2)
        #expect(results.first?.isError == true)
        #expect(results.first?.content.contains("timed out") == true)

        guard case let .finished(_, content, _, _) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(try content == encodedReport(documentID: "doc-1", summary: "quick"))
    }

    @Test
    func aDeniedCompletionEmitsApprovalEventsAndFeedsTheDenialBack() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [
                finalizeDeltas(id: "call_finalize_1", summary: "first"),
                finalizeDeltas(id: "call_finalize_2", summary: "second"),
            ],
            completionTool: finalize,
            configuration: AgentConfiguration(maxIterations: 2, approvalPolicy: .allTools)
        )
        let approvals = CountingApprovalHandler(decisions: ["finalize": .deny(reason: "Needs review")])

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1"),
            approvalHandler: approvals.handler
        ))

        #expect(events.contains { event in
            if case let .toolApprovalRequested(request) = event.kind { return request.toolName == "finalize" }
            return false
        })
        #expect(events.contains { event in
            if case let .toolApprovalResolved(_, decision) = event.kind {
                return decision == .deny(reason: "Needs review")
            }
            return false
        })
        #expect(completedToolResults(events, name: "finalize") == [
            .error("Needs review"), .error("Needs review"),
        ])
        #expect(await invocations.value == 0)
        #expect(await approvals.requestCount == 2)

        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected a structural finished event")
            return
        }
        #expect(content == nil)
        #expect(reason == .maxIterationsReached(limit: 2))
    }

    @Test
    func anExclusivityViolationClosesEveryToolRowAndRecovers() async throws {
        let lookupInvocations = ToolInvocationCounter()
        let completionInvocations = ToolInvocationCounter()
        let lookup = try makeLookupTool { _, _ in
            await lookupInvocations.increment()
            return LookupOutput(matches: 1)
        }
        let finalize = try makeFinalizeTool { params, context in
            await completionInvocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [
                lookupBesideFinalizeDeltas,
                finalizeDeltas(id: "call_finalize_2", summary: "all done"),
            ],
            tools: [lookup],
            completionTool: finalize
        )
        let backend = InMemoryCheckpointer()
        let session = SessionID()

        let events = try await collect(agent.stream(
            userMessage: "Go", context: ReportContext(documentID: "doc-1"),
            sessionID: session, checkpointer: backend
        ))

        #expect(await lookupInvocations.value == 0)
        #expect(await completionInvocations.value == 1)
        #expect(startedToolCallIDs(events) == ["call_lookup", "call_finalize_1", "call_finalize_2"])
        #expect(completedToolCallIDs(events) == ["call_lookup", "call_finalize_1", "call_finalize_2"])

        let violationResults = events.compactMap { event -> ToolResult? in
            guard case let .toolCallCompleted(id, _, result) = event.kind,
                  id == "call_lookup" || id == "call_finalize_1"
            else { return nil }
            return result
        }
        #expect(violationResults.count == 2)
        #expect(violationResults.first?.isError == true)
        #expect(violationResults.first == violationResults.last)

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(content == expected)
        #expect(reason == .completed)

        let ids = try await backend.list(session: session)
        #expect(ids.count == 2)
        let feedbackCheckpoint = try await backend.load(ids[0])
        let terminalCheckpoint = try await backend.load(ids[1])
        #expect(feedbackCheckpoint.terminalOutcome == nil)
        #expect(toolMessageContents(feedbackCheckpoint.messages) == violationResults.map(\.content))
        #expect(terminalCheckpoint.terminalOutcome == AgentTerminalOutcome(
            content: expected, toolName: "finalize"
        ))
    }

    @Test
    func pruneContextInsideAViolatingBatchIsNotExecuted() async throws {
        let lookupInvocations = ToolInvocationCounter()
        let lookup = try makeLookupTool { _, _ in
            await lookupInvocations.increment()
            return LookupOutput(matches: 7)
        }
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [
                lookupDeltas,
                pruneBesideFinalizeDeltas,
                finalizeDeltas(id: "call_finalize_2", summary: "all done"),
            ],
            tools: [lookup],
            completionTool: finalize,
            configuration: AgentConfiguration(
                contextBudget: ContextBudgetConfig(enablePruneTool: true)
            )
        )

        let events = try await collect(agent.stream(
            userMessage: "Go", context: ReportContext(documentID: "doc-1")
        ))

        let pruneResult = try #require(completedToolResults(events, name: "prune_context").first)
        #expect(pruneResult.isError)
        #expect(await lookupInvocations.value == 1)

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        guard case let .finished(_, content, reason, history) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(content == expected)
        #expect(reason == .completed)
        #expect(toolMessageContents(history) == [
            #"{"matches":7}"#, pruneResult.content, pruneResult.content, expected,
        ])
    }

    @Test
    func aLoneHallucinatedFinishCallBecomesUnknownToolFeedback() async throws {
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [hallucinatedFinishDeltas, finalizeDeltas(summary: "all done")],
            completionTool: finalize
        )

        let events = try await collect(agent.stream(
            userMessage: "Go", context: ReportContext(documentID: "doc-1")
        ))

        #expect(completedToolResults(events, name: "finish") == [
            .error(AgentError.toolNotFound(name: "finish").feedbackMessage),
        ])

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(content == expected)
        #expect(reason == .completed)
    }

    @Test
    func cancellationDuringTheCompletionToolCommitsNothing() async throws {
        let finalize = try makeFinalizeTool { _, _ in
            try await Task.sleep(for: .seconds(60))
            return FinalizeOutput(report: "completed without cancellation")
        }
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let agent = makeAgent(
            streamSequences: [finalizeDeltas(summary: "all done")],
            completionTool: finalize
        )
        let collector = StreamingEventCollector()
        let consumer = Task {
            for try await event in agent.stream(
                userMessage: "Summarize", context: ReportContext(documentID: "doc-1"),
                sessionID: session, checkpointer: backend
            ) {
                await collector.append(event)
            }
        }

        await awaitCollected(collector) { $0.kind == .toolCallStarted(name: "finalize", id: "call_finalize") }
        consumer.cancel()
        try? await consumer.value

        let events = await collector.events
        #expect(!events.contains(where: isFinished))
        #expect(completedToolResults(events, name: "finalize").isEmpty)
        #expect(try await backend.list(session: session).isEmpty)
    }
}

struct CustomCompletionStreamBudgetTests {
    @Test
    func aCommittedCompletionOutranksAnExceededTokenBudget() async throws {
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [finalizeDeltas(summary: "all done", usage: TokenUsage(input: 100, output: 100))],
            completionTool: finalize
        )

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1"), tokenBudget: 50
        ))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        guard case let .finished(usage, content, reason, _) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(usage == TokenUsage(input: 100, output: 100))
        #expect(content == expected)
        #expect(reason == .completed)
    }

    @Test
    func aCommittedCompletionAdvancesBudgetStateWithoutContinuationEffects() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [finalizeDeltas(summary: "all done", usage: TokenUsage(input: 85, output: 10))],
            completionTool: finalize,
            contextWindowSize: 100,
            configuration: AgentConfiguration(
                contextBudget: ContextBudgetConfig(softThreshold: 0.1, enableVisibility: true)
            )
        )

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1"),
            sessionID: session, checkpointer: backend
        ))

        let budgets = events.compactMap { event -> ContextBudget? in
            guard case let .budgetUpdated(budget) = event.kind else { return nil }
            return budget
        }
        #expect(budgets.map(\.currentUsage) == [95])
        #expect(!events.contains { event in
            if case .budgetAdvisory = event.kind { return true }
            return false
        })

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        guard case let .finished(_, content, _, history) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(content == expected)
        #expect(history.count == 3)
        #expect(toolMessageContents(history) == [expected])

        let ids = try await backend.list(session: session)
        let checkpoint = try await backend.load(#require(ids.first))
        let budgetState = try #require(checkpoint.contextBudgetState)
        #expect(budgetState.lastBudget?.currentUsage == 95)
        #expect(budgetState.softAdvisoryArmed)
    }
}

struct CustomCompletionStreamBoundaryTests {
    @Test
    func customModeStreamsTheCallersDefinitionsWithoutTheBuiltInFinishTool() async throws {
        let lookup = try makeLookupTool { _, _ in LookupOutput(matches: 1) }
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let client = StreamingMockLLMClient(streamSequences: [finalizeDeltas(summary: "all done")])
        let agent = Agent<ReportContext>(client: client, tools: [lookup], completionTool: finalize)

        _ = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let definitions = try #require(await client.allCapturedTools.first)
        #expect(definitions == [ToolDefinition(lookup), ToolDefinition(finalize)])
    }

    @Test
    func defaultModeStillStreamsTheBuiltInFinishTool() async throws {
        let lookup = try makeLookupTool { _, _ in LookupOutput(matches: 1) }
        let client = StreamingMockLLMClient(streamSequences: [[
            .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil),
        ]])
        let agent = Agent<ReportContext>(client: client, tools: [lookup])

        _ = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let definitions = try #require(await client.allCapturedTools.first)
        #expect(definitions == [ToolDefinition(lookup), reservedFinishToolDefinition])
    }
}

@MainActor
struct CustomCompletionStreamObserverTests {
    @Test
    func currentCheckpointAddressesTheTerminalCheckpointAfterTheCommittedFinish() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [finalizeDeltas(summary: "all done", usage: TokenUsage(input: 12, output: 4))],
            completionTool: finalize
        )
        let stream = AgentStream(agent: agent)

        stream.send(
            "Summarize", context: ReportContext(documentID: "doc-1"),
            sessionID: session, checkpointer: backend
        )
        await awaitStreamCompletion(stream)

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        let ids = try await backend.list(session: session)
        #expect(ids.count == 1)
        #expect(stream.currentCheckpoint == ids.first)
        #expect(stream.terminalContent == expected)
        #expect(stream.finishReason == .completed)

        let checkpoint = try await backend.load(#require(stream.currentCheckpoint))
        #expect(checkpoint.terminalOutcome == AgentTerminalOutcome(content: expected, toolName: "finalize"))
    }

    @Test
    func aNestedChildFinishStaysObservableWhenTheParentSaveFails() async throws {
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: StreamingMockLLMClient(streamSequences: [[
                .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
                .toolCallDelta(index: 0, arguments: #"{"content":"child result"}"#),
                .finished(usage: TokenUsage(input: 3, output: 2)),
            ]]),
            tools: []
        )
        let delegate = try SubAgentTool<LookupParams, EmptyContext>(
            name: "delegate",
            description: "Delegates the final answer. Call it alone.",
            agent: childAgent,
            messageBuilder: { $0.query }
        )
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: StreamingMockLLMClient(streamSequences: [[
                .toolCallStart(index: 0, id: "delegate_call", name: "delegate", kind: .function),
                .toolCallDelta(index: 0, arguments: #"{"query": "wrap up"}"#),
                .finished(usage: TokenUsage(input: 10, output: 5)),
            ]]),
            tools: [],
            completionTool: delegate
        )
        let checkpointer = FailingSaveCheckpointer()
        let stream = AgentStream(agent: parentAgent, bufferCapacity: 64)

        stream.send(
            "Go", context: SubAgentContext(inner: EmptyContext(), maxDepth: 3),
            checkpointer: checkpointer
        )
        await awaitStreamCompletion(stream)

        let replayed = try await collect(stream.replay(from: 0))
        #expect(replayed.contains { event in
            if case let .subAgentEvent(_, toolName, nested) = event.kind, toolName == "delegate" {
                return isFinished(nested)
            }
            return false
        })
        let delegateCall = try #require(stream.toolCalls.first { $0.id == "delegate_call" })
        guard case let .completed(result) = delegateCall.state else {
            Issue.record("Expected the parent completion row to be closed before the save")
            return
        }
        #expect(result == "child result")

        #expect(stream.terminalContent == nil)
        #expect(stream.finishReason == nil)
        #expect(stream.tokenUsage == nil)
        #expect(stream.history.isEmpty)
        #expect(stream.currentCheckpoint == nil)
        #expect(await checkpointer.saveCount == 1)
        #expect(stream.error as? CustomCompletionTestError == .checkpointStorageUnavailable)
    }
}
