import Foundation

extension Agent {
    @discardableResult
    func checkpointIfConfigured(
        iterationNumber: Int,
        state: AgentLoopState,
        totalUsage: TokenUsageTotals,
        iterationUsage: TokenUsage?,
        eventFactory: StreamEventFactory,
        checkpointer: (any AgentCheckpointer)?,
        terminalOutcome: AgentTerminalOutcome? = nil
    ) async throws -> CheckpointID? {
        guard let checkpointer,
              let sessionID = eventFactory.sessionID,
              let runID = eventFactory.runID
        else { return nil }
        let checkpoint = AgentCheckpoint(
            messages: state.messages,
            iteration: iterationNumber,
            tokenUsage: totalUsage,
            iterationUsage: iterationUsage,
            contextBudgetState: state.budgetPhase?.checkpointState,
            historyWasRewrittenLocally: state.historyWasRewrittenLocally,
            sessionAllowlist: state.sessionAllowlist,
            sessionID: sessionID,
            runID: runID,
            checkpointID: CheckpointID(),
            timestamp: Date(),
            mcpToolBindings: mcpToolBindings(in: state.messages),
            terminalOutcome: terminalOutcome
        )
        try await checkpointer.save(checkpoint)
        return checkpoint.checkpointID
    }

    func mcpToolBindings(in messages: [ChatMessage]) -> Set<MCPToolBinding> {
        let participatingNames = Set(messages.flatMap { message -> [String] in
            switch message {
            case let .assistant(assistant): return assistant.toolCalls.map(\.name)
            case let .tool(_, name, _): return [name]
            default: return []
            }
        })
        return Set(tools.compactMap { tool in
            guard participatingNames.contains(tool.name),
                  let mcpTool = tool as? MCPTool<C>
            else { return nil }
            return mcpTool.checkpointBinding
        })
    }
}
