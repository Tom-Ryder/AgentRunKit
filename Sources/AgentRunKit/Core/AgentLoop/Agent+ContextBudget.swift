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

    func applyBudgetPhase(
        _ budgetPhase: inout ContextBudgetPhase?,
        usage: TokenUsage,
        messages: inout [ChatMessage],
        emit: StreamEmitter? = nil
    ) {
        guard var phase = budgetPhase else { return }
        let result = phase.afterResponse(usage: usage, messages: &messages)
        budgetPhase = phase
        emit?.yield(.budgetUpdated(budget: result.budget))
        if result.advisoryEmitted {
            emit?.yield(.budgetAdvisory(budget: result.budget))
        }
    }

    @discardableResult
    func executePruneCalls(
        _ calls: [IndexedToolCall],
        messages: inout [ChatMessage],
        emit: StreamEmitter? = nil
    ) -> (historyWasRewritten: Bool, results: [IndexedToolResult]) {
        let pruneEnabled = configuration.contextBudget?.enablePruneTool == true
        var historyWasRewritten = false
        var results: [IndexedToolResult] = []
        for indexed in calls {
            let result: ToolResult
            if !pruneEnabled {
                result = .error("Tool not available: prune_context is disabled.")
            } else {
                do {
                    let pruneResult = try executePruneContext(
                        arguments: indexed.call.argumentsData,
                        messages: &messages
                    )
                    result = pruneResult.toolResult
                    historyWasRewritten = historyWasRewritten || pruneResult.historyWasRewritten
                } catch {
                    result = .error("prune_context failed: \(error)")
                }
            }
            results.append(IndexedToolResult(index: indexed.index, call: indexed.call, result: result))
            emit?.yield(.toolCallCompleted(
                id: indexed.call.id, name: indexed.call.name, result: result
            ))
        }
        return (historyWasRewritten: historyWasRewritten, results: results)
    }

    func executeResults(
        _ calls: [IndexedToolCall], context: C, messages: [ChatMessage],
        approvalHandler: ToolApprovalHandler? = nil, allowlist: inout Set<String>
    ) async throws -> [IndexedToolResult] {
        guard !calls.isEmpty else { return [] }
        let executionContext = context.withParentHistory(messages.resolvedPrefixForInheritance())

        guard let handler = approvalHandler, configuration.approvalPolicy != .none else {
            return try await executeIndexedCalls(
                calls,
                context: executionContext,
                approvalHandler: approvalHandler
            )
        }

        let (autoExecute, needsApproval) = partitionCallsRequiringApproval(calls, allowlist: allowlist)
        var allResults = try await executeIndexedCalls(autoExecute, context: executionContext, approvalHandler: handler)

        let (approved, denied) = try await resolveApprovals(
            needsApproval, handler: handler, allowlist: &allowlist
        )
        try Task.checkCancellation()

        allResults.append(contentsOf: denied.map(truncatedIndexedToolResult))
        try await allResults.append(contentsOf: executeIndexedCalls(
            approved,
            context: executionContext,
            approvalHandler: handler
        ))
        return allResults.sorted { $0.index < $1.index }
    }

    func executeStreamingResults(
        _ calls: [IndexedToolCall], context: C, messages: [ChatMessage],
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        allowlist: inout Set<String>
    ) async throws -> [IndexedToolResult] {
        guard !calls.isEmpty else { return [] }
        let executionContext = context.withParentHistory(messages.resolvedPrefixForInheritance())
        let approvalHandler = options.approvalHandler
        let emit = StreamEmitter(factory: options.eventFactory, continuation: continuation)

        guard let handler = approvalHandler, configuration.approvalPolicy != .none else {
            return try await executeIndexedStreamingCalls(
                calls,
                context: executionContext,
                options: options,
                continuation: continuation
            )
        }

        let (autoExecute, needsApproval) = partitionCallsRequiringApproval(calls, allowlist: allowlist)
        var allResults = try await executeIndexedStreamingCalls(
            autoExecute,
            context: executionContext,
            options: options,
            continuation: continuation
        )

        let (approved, denied) = try await resolveApprovals(
            needsApproval, handler: handler, emit: emit, allowlist: &allowlist
        )
        try Task.checkCancellation()

        for entry in denied {
            let truncatedEntry = truncatedIndexedToolResult(entry)
            emit.yield(.toolCallCompleted(
                id: truncatedEntry.call.id, name: truncatedEntry.call.name, result: truncatedEntry.result
            ))
            allResults.append(truncatedEntry)
        }

        try await allResults.append(contentsOf: executeIndexedStreamingCalls(
            approved,
            context: executionContext,
            options: options,
            continuation: continuation
        ))
        return allResults.sorted { $0.index < $1.index }
    }

    func appendToolResults(_ results: [IndexedToolResult], messages: inout [ChatMessage]) {
        for entry in results {
            messages.append(.tool(id: entry.call.id, name: entry.call.name, content: entry.result.content))
        }
    }

    func toolResultCharacterLimit(for toolName: String) -> Int? {
        tool(named: toolName)?.maxResultCharacters ?? configuration.maxToolResultCharacters
    }

    func truncatedToolResult(_ result: ToolResult, toolName: String) -> ToolResult {
        ContextCompactor.truncateToolResult(result, maxCharacters: toolResultCharacterLimit(for: toolName))
    }

    private func partitionCallsRequiringApproval(
        _ calls: [IndexedToolCall],
        allowlist: Set<String>
    ) -> (autoExecute: [IndexedToolCall], needsApproval: [IndexedToolCall]) {
        var autoExecute: [IndexedToolCall] = []
        var needsApproval: [IndexedToolCall] = []
        for indexed in calls {
            if requiresApproval(indexed.call, allowlist: allowlist) {
                needsApproval.append(indexed)
            } else {
                autoExecute.append(indexed)
            }
        }
        return (autoExecute: autoExecute, needsApproval: needsApproval)
    }

    private func executeIndexedCalls(
        _ calls: [IndexedToolCall],
        context: C,
        approvalHandler: ToolApprovalHandler?
    ) async throws -> [IndexedToolResult] {
        let results = try await executeToolsInParallel(
            calls.map(\.call),
            context: context,
            approvalHandler: approvalHandler
        )
        return zip(calls, results).map { indexed, entry in
            IndexedToolResult(
                index: indexed.index,
                call: entry.call,
                result: truncatedToolResult(entry.result, toolName: entry.call.name)
            )
        }
    }

    private func executeIndexedStreamingCalls(
        _ calls: [IndexedToolCall],
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> [IndexedToolResult] {
        let results = try await executeToolsStreaming(
            calls.map(\.call),
            context: context,
            options: options,
            continuation: continuation
        )
        return zip(calls, results).map { indexed, entry in
            IndexedToolResult(
                index: indexed.index,
                call: entry.call,
                result: entry.result
            )
        }
    }

    private func truncatedIndexedToolResult(_ entry: IndexedToolResult) -> IndexedToolResult {
        IndexedToolResult(
            index: entry.index,
            call: entry.call,
            result: truncatedToolResult(entry.result, toolName: entry.call.name)
        )
    }
}
