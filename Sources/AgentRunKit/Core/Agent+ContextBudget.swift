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
        continuation?.yield(.make(.budgetUpdated(budget: result.budget)))
        if result.advisoryEmitted {
            continuation?.yield(.make(.budgetAdvisory(budget: result.budget)))
        }
    }

    @discardableResult
    func executePruneCalls(
        _ calls: [ToolCall],
        messages: inout [ChatMessage],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation? = nil
    ) -> Bool {
        let pruneEnabled = configuration.contextBudget?.enablePruneTool == true
        var historyWasRewritten = false
        for call in calls {
            let result: ToolResult
            if !pruneEnabled {
                result = .error("Tool not available: prune_context is disabled.")
            } else {
                do {
                    let pruneResult = try executePruneContext(arguments: call.argumentsData, messages: &messages)
                    result = pruneResult.toolResult
                    historyWasRewritten = historyWasRewritten || pruneResult.historyWasRewritten
                } catch {
                    result = .error("prune_context failed: \(error)")
                }
            }
            messages.append(.tool(id: call.id, name: call.name, content: result.content))
            continuation?.yield(.make(.toolCallCompleted(id: call.id, name: call.name, result: result)))
        }
        return historyWasRewritten
    }

    func executeAndAppendResults(
        _ calls: [ToolCall], context: C, messages: inout [ChatMessage],
        approvalHandler: ToolApprovalHandler? = nil, allowlist: inout Set<String>
    ) async throws {
        guard !calls.isEmpty else { return }
        let executionContext = context.withParentHistory(messages)

        guard let handler = approvalHandler, configuration.approvalPolicy != .none else {
            let results = try await executeToolsInParallel(
                calls,
                context: executionContext,
                approvalHandler: approvalHandler
            )
            for (call, result) in results {
                let content = ContextCompactor.truncateToolResult(result.content, configuration: configuration)
                messages.append(.tool(id: call.id, name: call.name, content: content))
            }
            return
        }

        var autoExecute: [IndexedToolCall] = []
        var needsApproval: [IndexedToolCall] = []
        for (offset, call) in calls.enumerated() {
            let indexed = IndexedToolCall(index: offset, call: call)
            if requiresApproval(call, allowlist: allowlist) {
                needsApproval.append(indexed)
            } else {
                autoExecute.append(indexed)
            }
        }

        var allResults: [IndexedToolResult] = []

        if !autoExecute.isEmpty {
            let results = try await executeToolsInParallel(
                autoExecute.map(\.call), context: executionContext, approvalHandler: handler
            )
            for (position, (call, result)) in results.enumerated() {
                allResults.append(IndexedToolResult(index: autoExecute[position].index, call: call, result: result))
            }
        }

        let (approved, denied) = try await resolveApprovals(
            needsApproval, handler: handler, allowlist: &allowlist, continuation: nil
        )
        try Task.checkCancellation()

        allResults.append(contentsOf: denied)

        if !approved.isEmpty {
            let results = try await executeToolsInParallel(
                approved.map(\.call), context: executionContext, approvalHandler: handler
            )
            for (position, (call, result)) in results.enumerated() {
                allResults.append(IndexedToolResult(index: approved[position].index, call: call, result: result))
            }
        }

        allResults.sort { $0.index < $1.index }
        for entry in allResults {
            let content = ContextCompactor.truncateToolResult(entry.result.content, configuration: configuration)
            messages.append(.tool(id: entry.call.id, name: entry.call.name, content: content))
        }
    }

    func executeStreamingAndAppendResults(
        _ calls: [ToolCall], context: C, messages: inout [ChatMessage],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        approvalHandler: ToolApprovalHandler? = nil, allowlist: inout Set<String>
    ) async throws {
        guard !calls.isEmpty else { return }
        let executionContext = context.withParentHistory(messages)

        guard let handler = approvalHandler, configuration.approvalPolicy != .none else {
            let results = try await executeToolsStreaming(
                calls,
                context: executionContext,
                continuation: continuation,
                approvalHandler: approvalHandler
            )
            for (call, result) in results {
                let content = ContextCompactor.truncateToolResult(result.content, configuration: configuration)
                messages.append(.tool(id: call.id, name: call.name, content: content))
            }
            return
        }

        var autoExecute: [IndexedToolCall] = []
        var needsApproval: [IndexedToolCall] = []
        for (offset, call) in calls.enumerated() {
            let indexed = IndexedToolCall(index: offset, call: call)
            if requiresApproval(call, allowlist: allowlist) {
                needsApproval.append(indexed)
            } else {
                autoExecute.append(indexed)
            }
        }

        var allResults: [IndexedToolResult] = []

        if !autoExecute.isEmpty {
            let results = try await executeToolsStreaming(
                autoExecute.map(\.call), context: executionContext,
                continuation: continuation, approvalHandler: handler
            )
            for (position, (call, result)) in results.enumerated() {
                allResults.append(IndexedToolResult(index: autoExecute[position].index, call: call, result: result))
            }
        }

        let (approved, denied) = try await resolveApprovals(
            needsApproval, handler: handler, allowlist: &allowlist, continuation: continuation
        )
        try Task.checkCancellation()

        for entry in denied {
            continuation.yield(.make(.toolCallCompleted(
                id: entry.call.id, name: entry.call.name, result: entry.result
            )))
            allResults.append(entry)
        }

        if !approved.isEmpty {
            let results = try await executeToolsStreaming(
                approved.map(\.call), context: executionContext,
                continuation: continuation, approvalHandler: handler
            )
            for (position, (call, result)) in results.enumerated() {
                allResults.append(IndexedToolResult(index: approved[position].index, call: call, result: result))
            }
        }

        allResults.sort { $0.index < $1.index }
        for entry in allResults {
            let content = ContextCompactor.truncateToolResult(entry.result.content, configuration: configuration)
            messages.append(.tool(id: entry.call.id, name: entry.call.name, content: content))
        }
    }
}
