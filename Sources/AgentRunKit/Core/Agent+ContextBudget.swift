import Foundation

extension Agent {
    func makeBudgetPhase() throws -> ContextBudgetPhase? {
        guard let budgetConfig = configuration.contextBudget,
              budgetConfig.requiresUsageTracking
        else {
            return nil
        }
        guard let windowSize = client.contextWindowSize else {
            throw AgentError.contextBudgetWindowSizeUnavailable
        }
        return ContextBudgetPhase(config: budgetConfig, windowSize: windowSize)
    }

    func requireBudgetUsage(_ usage: TokenUsage?, budgetPhase: ContextBudgetPhase?) throws -> TokenUsage? {
        guard budgetPhase != nil else { return usage }
        guard let usage else {
            throw AgentError.contextBudgetUsageUnavailable
        }
        return usage
    }

    func applyBudgetPhase(
        _ budgetPhase: inout ContextBudgetPhase?,
        usage: TokenUsage,
        messages: inout [ChatMessage],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation? = nil
    ) {
        guard var phase = budgetPhase else { return }
        let result = phase.afterResponse(usage: usage, messages: &messages)
        budgetPhase = phase
        continuation?.yield(.budgetUpdated(budget: result.budget))
        if result.advisoryEmitted {
            continuation?.yield(.budgetAdvisory(budget: result.budget))
        }
    }

    func executePruneCalls(
        _ calls: [ToolCall],
        messages: inout [ChatMessage],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation? = nil
    ) {
        let pruneEnabled = configuration.contextBudget?.enablePruneTool == true
        for call in calls {
            let result: ToolResult
            if !pruneEnabled {
                result = .error("Tool not available: prune_context is disabled.")
            } else {
                do {
                    result = try executePruneContext(arguments: call.argumentsData, messages: &messages)
                } catch {
                    result = .error("prune_context failed: \(error)")
                }
            }
            messages.append(.tool(id: call.id, name: call.name, content: result.content))
            continuation?.yield(.toolCallCompleted(id: call.id, name: call.name, result: result))
        }
    }

    func executeAndAppendResults(
        _ calls: [ToolCall], context: C, messages: inout [ChatMessage]
    ) async throws {
        guard !calls.isEmpty else { return }
        let results = try await executeToolsInParallel(calls, context: context.withParentHistory(messages))
        for (call, result) in results {
            let content = ContextCompactor.truncateToolResult(result.content, configuration: configuration)
            messages.append(.tool(id: call.id, name: call.name, content: content))
        }
    }

    func executeStreamingAndAppendResults(
        _ calls: [ToolCall], context: C, messages: inout [ChatMessage],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        guard !calls.isEmpty else { return }
        let results = try await executeToolsStreaming(
            calls, context: context.withParentHistory(messages), continuation: continuation
        )
        for (call, result) in results {
            let content = ContextCompactor.truncateToolResult(result.content, configuration: configuration)
            messages.append(.tool(id: call.id, name: call.name, content: content))
        }
    }
}
