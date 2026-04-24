@testable import AgentRunKit
import Foundation
import Testing

private let anthropicAPIKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
private let hasAnthropicKey = !anthropicAPIKey.isEmpty
private let anthropicModel = ProcessInfo.processInfo.environment["SMOKE_ANTHROPIC_MODEL"] ?? "claude-sonnet-4-6"

@Suite(.enabled(if: hasAnthropicKey, "Requires ANTHROPIC_API_KEY environment variable"))
struct ResumeCheckpointSmokeTests {
    private func makeClient() throws -> AnthropicClient {
        try AnthropicClient(apiKey: anthropicAPIKey, model: anthropicModel, maxTokens: 1024)
    }

    private func makeAddOnlyAgent(
        client: AnthropicClient,
        maxIterations: Int = 5
    ) throws -> Agent<EmptyContext> {
        let addTool = try makeSmokeAddTool()
        let config = AgentConfiguration(
            maxIterations: maxIterations,
            systemPrompt: """
            You are a calculator assistant. When asked to add numbers, use the add tool.
            After getting the result, use the finish tool with the answer.
            """
        )
        return Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)
    }

    @Test
    func resumeAfterInMemoryCheckpointFinishesLive() async throws {
        let client = try makeClient()
        let backend = InMemoryCheckpointer()
        let agent = try makeAddOnlyAgent(client: client)
        let session = SessionID()

        var firstStreamEvents: [StreamEvent] = []
        for try await event in agent.stream(
            userMessage: "What is 17 + 25? Use the add tool, then finish.",
            context: EmptyContext(),
            sessionID: session,
            checkpointer: backend
        ) {
            firstStreamEvents.append(event)
        }

        let savedIDs = try await backend.list(session: session)
        let firstID = try #require(savedIDs.first)

        let resumeStream = try await agent.resume(
            from: firstID, checkpointer: backend, context: EmptyContext()
        )
        var resumedEvents: [StreamEvent] = []
        for try await event in resumeStream {
            resumedEvents.append(event)
        }

        let replayedCount = resumedEvents.count { event in
            if case .replayed = event.origin, case .iterationCompleted = event.kind { return true }
            return false
        }
        let liveFinish = resumedEvents.last { event in
            if case .finished = event.kind, event.origin == .live { return true }
            return false
        }
        try smokeExpect(replayedCount >= 1)
        try smokeExpect(liveFinish != nil)
        if case let .finished(_, content, _, _) = liveFinish?.kind {
            try smokeExpect(content?.contains("42") == true)
        }
    }

    @Test
    func resumeAcrossFileCheckpointerInstances() async throws {
        let client = try makeClient()
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "agent-resume-smoke-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = SessionID()
        let writer = FileCheckpointer(directory: directory)
        let firstAgent = try makeAddOnlyAgent(client: client)
        for try await _ in firstAgent.stream(
            userMessage: "What is 7 + 8? Use the add tool, then finish.",
            context: EmptyContext(),
            sessionID: session,
            checkpointer: writer
        ) {}

        let writerIDs = try await writer.list(session: session)
        let firstID = try #require(writerIDs.first)

        let reader = FileCheckpointer(directory: directory)
        let freshAgent = try makeAddOnlyAgent(client: client)
        let resumeStream = try await freshAgent.resume(
            from: firstID, checkpointer: reader, context: EmptyContext()
        )
        var liveContent: String?
        for try await event in resumeStream {
            if case let .finished(_, content, _, _) = event.kind, event.origin == .live {
                liveContent = content
            }
        }
        try smokeExpect(liveContent?.contains("15") == true)
    }

    @MainActor @Test
    func agentStreamResumePreloadsCheckpointStateBeforeFirstLiveRequest() async throws {
        let client = try makeClient()
        let backend = InMemoryCheckpointer()
        let agent = try makeAddOnlyAgent(client: client)
        let session = SessionID()

        let initialStream = AgentStream(agent: agent, bufferCapacity: 256)
        initialStream.send(
            "What is 30 + 12? Use the add tool, then finish.",
            context: EmptyContext(),
            sessionID: session,
            checkpointer: backend
        )
        while initialStream.isStreaming {
            await Task.yield()
        }
        let savedIDs = try await backend.list(session: session)
        let firstID = try #require(savedIDs.first)

        let resumedStream = AgentStream(agent: agent, bufferCapacity: 256)
        try await resumedStream.resume(
            from: firstID, checkpointer: backend, context: EmptyContext()
        )
        try smokeExpect(resumedStream.sessionID == session)
        try smokeExpect(resumedStream.currentCheckpoint == firstID)
        try smokeExpect(!resumedStream.history.isEmpty)
        try smokeExpect(resumedStream.tokenUsage != nil)
        while resumedStream.isStreaming {
            await Task.yield()
        }
        try smokeExpect(resumedStream.iterationsReplayed >= 1)
        try smokeExpect(resumedStream.finishReason == .completed)
        try smokeExpect(resumedStream.content.contains("42"))
    }

    @Test
    func crashRecoveryResumesFromMidFlowAndCompletes() async throws {
        let client = try makeClient()
        let backend = InMemoryCheckpointer()
        let agent = try makeAddOnlyAgent(client: client, maxIterations: 6)
        let session = SessionID()

        let firstStream = agent.stream(
            userMessage: "Use the add tool to compute (3 + 4) + 5. Then finish with the result.",
            context: EmptyContext(), sessionID: session, checkpointer: backend
        )
        var sawToolResult = false
        for try await event in firstStream {
            if case .toolCallCompleted = event.kind, event.origin == .live {
                sawToolResult = true
            }
            if sawToolResult, case .iterationCompleted = event.kind, event.origin == .live {
                break
            }
        }
        let savedIDs = try await backend.list(session: session)
        let lastSaved = try #require(savedIDs.last)

        let resumedAgent = try makeAddOnlyAgent(client: client, maxIterations: 6)
        let resumeStream = try await resumedAgent.resume(
            from: lastSaved, checkpointer: backend, context: EmptyContext()
        )
        var liveContent: String?
        for try await event in resumeStream {
            if case let .finished(_, content, reason, _) = event.kind, event.origin == .live {
                liveContent = content
                try smokeExpect(reason == .completed)
            }
        }
        try smokeExpect(liveContent?.contains("12") == true)
    }

    @Test
    func resumeFromEarlierCheckpointReplaysCorrectIterationOnly() async throws {
        let client = try makeClient()
        let backend = InMemoryCheckpointer()
        let agent = try makeAddOnlyAgent(client: client, maxIterations: 6)
        let session = SessionID()

        for try await _ in agent.stream(
            userMessage: "Use the add tool to compute 10 + 20. Then finish with the result.",
            context: EmptyContext(), sessionID: session, checkpointer: backend
        ) {}

        let savedIDs = try await backend.list(session: session)
        try smokeExpect(savedIDs.count >= 1)
        let firstID = try #require(savedIDs.first)
        let firstCheckpoint = try await backend.load(firstID)

        let resumeStream = try await agent.resume(
            from: firstID, checkpointer: backend, context: EmptyContext()
        )
        var replayedCheckpointIDs: [CheckpointID] = []
        for try await event in resumeStream {
            if case .iterationCompleted = event.kind, case let .replayed(from) = event.origin {
                replayedCheckpointIDs.append(from)
            }
        }
        try smokeExpect(replayedCheckpointIDs == [firstID])
        try smokeExpect(firstCheckpoint.iteration >= 1)
    }

    @Test
    func resumeOverTokenBudgetSkipsLLMCallButReplaysCheckpoint() async throws {
        let client = try makeClient()
        let backend = InMemoryCheckpointer()
        let agent = try makeAddOnlyAgent(client: client)
        let session = SessionID()

        for try await _ in agent.stream(
            userMessage: "What is 4 + 5? Use the add tool, then finish.",
            context: EmptyContext(),
            sessionID: session,
            checkpointer: backend
        ) {}
        let savedIDs = try await backend.list(session: session)
        let firstID = try #require(savedIDs.first)

        let stream = try await agent.resume(
            from: firstID, checkpointer: backend, context: EmptyContext(),
            tokenBudget: 1
        )
        var replayCount = 0
        var finishReason: FinishReason?
        for try await event in stream {
            if case .iterationCompleted = event.kind, case .replayed = event.origin {
                replayCount += 1
            }
            if case let .finished(_, _, reason, _) = event.kind {
                finishReason = reason
            }
        }
        try smokeExpect(replayCount >= 1)
        guard case .tokenBudgetExceeded = finishReason else {
            try smokeExpect(false, "Expected .tokenBudgetExceeded, got \(String(describing: finishReason))")
            return
        }
    }
}
