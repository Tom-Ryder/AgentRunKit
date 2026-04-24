import Foundation

extension Agent {
    /// Resumes a previously checkpointed run, replaying iteration history before continuing live.
    public func resume(
        from checkpointID: CheckpointID,
        checkpointer: any AgentCheckpointer,
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let target = try await checkpointer.load(checkpointID)
        return try await resume(
            target: target, checkpointer: checkpointer, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext,
            approvalHandler: approvalHandler
        )
    }

    func resume(
        target: AgentCheckpoint,
        checkpointer: any AgentCheckpointer,
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler,
            sessionID: target.sessionID, runID: RunID(),
            checkpointer: checkpointer
        )
        validateInvocation(options)
        try target.messages.validateForAgentHistory()
        try validateMCPBindings(target.mcpToolBindings)
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await replayAndContinueResume(
                        target: target, context: context,
                        options: options, continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func validateMCPBindings(_ checkpointed: Set<MCPToolBinding>) throws {
        guard !checkpointed.isEmpty else { return }
        let liveBindings: Set<MCPToolBinding> = Set(
            tools.compactMap { ($0 as? MCPTool<C>)?.checkpointBinding }
        )
        let missing = checkpointed.subtracting(liveBindings)
        guard missing.isEmpty else {
            throw AgentCheckpointError.mcpBindingMismatch(Array(missing))
        }
    }

    private func replayAndContinueResume(
        target: AgentCheckpoint,
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let replayFactory = StreamEventFactory(
            sessionID: target.sessionID,
            runID: target.runID,
            origin: .replayed(from: target.checkpointID)
        )
        continuation.yield(replayFactory.make(.iterationCompleted(
            usage: target.iterationUsage ?? TokenUsage(),
            iteration: target.iteration,
            history: target.messages
        )))
        var state = StreamingLoopState(
            messages: target.messages,
            historyWasRewrittenLocally: true,
            budgetPhase: target.contextBudgetState.map(ContextBudgetPhase.init(checkpointState:)),
            sessionAllowlist: target.sessionAllowlist
        )
        if let earlyFinish = earlyFinishEvent(target: target, options: options) {
            finishStreaming(continuation: continuation, event: earlyFinish)
            return
        }
        try await performStreamLoop(
            state: &state, startIteration: target.iteration + 1,
            totalUsage: target.tokenUsage, lastTotalTokens: target.iterationUsage?.total,
            context: context, options: options,
            continuation: continuation
        )
    }

    private func earlyFinishEvent(target: AgentCheckpoint, options: InvocationOptions) -> StreamEvent? {
        if let tokenBudget = options.tokenBudget, target.tokenUsage.total > tokenBudget {
            return makeFinishedEvent(
                tokenUsage: target.tokenUsage, content: nil,
                reason: .tokenBudgetExceeded(budget: tokenBudget, used: target.tokenUsage.total),
                history: target.messages, eventFactory: options.eventFactory
            )
        }
        if target.iteration >= configuration.maxIterations {
            return makeFinishedEvent(
                tokenUsage: target.tokenUsage, content: nil,
                reason: .maxIterationsReached(limit: configuration.maxIterations),
                history: target.messages, eventFactory: options.eventFactory
            )
        }
        return nil
    }
}
