import Foundation

struct IndexedToolCall {
    let index: Int
    let call: ToolCall
}

struct IndexedToolResult {
    let index: Int
    let call: ToolCall
    let result: ToolResult
}

extension Agent {
    func requiresApproval(_ call: ToolCall, allowlist: Set<String>) -> Bool {
        configuration.approvalPolicy.requiresApproval(toolName: call.name, allowlist: allowlist)
    }

    func resolveApprovals(
        _ calls: [IndexedToolCall],
        handler: @escaping ToolApprovalHandler,
        emit: StreamEmitter? = nil,
        allowlist: inout Set<String>
    ) async throws -> (approved: [IndexedToolCall], denied: [IndexedToolResult]) {
        var approved: [IndexedToolCall] = []
        var denied: [IndexedToolResult] = []

        for indexed in calls {
            guard let tool = firstTool(named: indexed.call.name, in: tools) else {
                approved.append(indexed)
                continue
            }

            if allowlist.contains(indexed.call.name) {
                approved.append(indexed)
                continue
            }

            let request = ToolApprovalRequest(
                toolCallId: indexed.call.id,
                toolName: indexed.call.name,
                arguments: indexed.call.arguments,
                toolDescription: tool.description
            )
            emit?.yield(.toolApprovalRequested(request))
            let decision = try await awaitApprovalDecision(for: request, using: handler)
            emit?.yield(.toolApprovalResolved(toolCallId: indexed.call.id, decision: decision))

            switch decision {
            case .approve:
                approved.append(indexed)
            case .approveAlways:
                allowlist.insert(indexed.call.name)
                approved.append(indexed)
            case let .approveWithModifiedArguments(newArgs):
                let modified = ToolCall(
                    id: indexed.call.id,
                    name: indexed.call.name,
                    arguments: newArgs,
                    kind: indexed.call.kind
                )
                approved.append(IndexedToolCall(index: indexed.index, call: modified))
            case let .deny(reason):
                let result = ToolResult.error(reason ?? ToolFeedback.denied)
                denied.append(IndexedToolResult(index: indexed.index, call: indexed.call, result: result))
            }
        }

        return (approved: approved, denied: denied)
    }

    func resolveTimeout(for call: ToolCall) -> Duration {
        guard let tool = firstTool(named: call.name, in: tools) else {
            return configuration.toolTimeout
        }
        return resolvedToolTimeout(for: tool, default: configuration.toolTimeout)
    }

    func executeWithTimeout(
        _ call: ToolCall, context: C, approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> ToolResult {
        do {
            return try await withToolTimeout(resolveTimeout(for: call), toolName: call.name) {
                if let handler = approvalHandler,
                   let tool = firstTool(named: call.name, in: self.tools),
                   let approvalAware = tool as? any ApprovalAwareSubAgentTool<C> {
                    return try await approvalAware.executeWithApproval(
                        arguments: call.argumentsData, context: context, approvalHandler: handler
                    )
                }
                return try await self.executeTool(call, context: context)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentError {
            return ToolResult.error(error.feedbackMessage)
        } catch {
            return ToolResult.error(ToolFeedback.failed(error))
        }
    }

    func executeStreamableWithTimeout(
        _ call: ToolCall,
        tool: any StreamableSubAgentTool<C>,
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> ToolResult {
        let eventFactory = options.eventFactory
        continuation.yield(eventFactory.make(.subAgentStarted(toolCallId: call.id, toolName: call.name)))

        let parentDepth = currentDepth(of: context)
        let eventHandler: @Sendable (StreamEvent) -> Void = { [self] event in
            let processed = applyHistoryEmissionLimitToSubAgentEvent(event, parentDepth: parentDepth)
            continuation.yield(eventFactory.make(
                .subAgentEvent(toolCallId: call.id, toolName: call.name, event: processed)
            ))
        }

        let result: ToolResult
        do {
            result = try await withToolTimeout(resolveTimeout(for: call), toolName: call.name) {
                try await tool.executeStreaming(
                    toolCallId: call.id, arguments: call.argumentsData,
                    context: context, parentSessionID: eventFactory.sessionID,
                    eventHandler: eventHandler, approvalHandler: options.approvalHandler
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentError {
            result = ToolResult.error(error.feedbackMessage)
        } catch {
            result = ToolResult.error(ToolFeedback.failed(error))
        }
        continuation.yield(eventFactory.make(
            .subAgentCompleted(toolCallId: call.id, toolName: call.name, result: result)
        ))
        return result
    }

    func executeToolsStreaming(
        _ calls: [ToolCall],
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> [(call: ToolCall, result: ToolResult)] {
        var allResults: [(call: ToolCall, result: ToolResult)] = []
        let eventFactory = options.eventFactory
        for wave in executionWaves(calls) {
            if wave.concurrent {
                try await allResults.append(contentsOf: executeConcurrentStreamingWave(
                    wave.calls, context: context, options: options, continuation: continuation
                ))
            } else {
                let call = wave.calls[0]
                let result: ToolResult = if let streamableTool = firstTool(named: call.name, in: tools)
                    as? any StreamableSubAgentTool<C> {
                    try await executeStreamableWithTimeout(
                        call, tool: streamableTool, context: context,
                        options: options, continuation: continuation
                    )
                } else {
                    try await executeWithTimeout(call, context: context, approvalHandler: options.approvalHandler)
                }
                let truncated = truncatedToolResult(
                    result,
                    toolName: call.name,
                    tools: tools,
                    fallbackLimit: configuration.maxToolResultCharacters
                )
                continuation.yield(eventFactory.make(
                    .toolCallCompleted(id: call.id, name: call.name, result: truncated)
                ))
                allResults.append((call, truncated))
            }
        }
        return allResults
    }

    func executeToolsInParallel(
        _ calls: [ToolCall],
        context: C,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> [(call: ToolCall, result: ToolResult)] {
        var allResults: [(call: ToolCall, result: ToolResult)] = []
        for wave in executionWaves(calls) {
            if wave.concurrent {
                try await allResults.append(contentsOf: executeConcurrentWave(
                    wave.calls, context: context, approvalHandler: approvalHandler
                ))
            } else {
                let call = wave.calls[0]
                let result = try await executeWithTimeout(
                    call, context: context, approvalHandler: approvalHandler
                )
                allResults.append((call, result))
            }
        }
        return allResults
    }

    func executeTool(_ call: ToolCall, context: C) async throws -> ToolResult {
        guard let tool = firstTool(named: call.name, in: tools) else {
            throw AgentError.toolNotFound(name: call.name)
        }
        return try await tool.execute(arguments: call.argumentsData, context: context)
    }

    private func executionWaves(_ calls: [ToolCall]) -> [ExecutionWave] {
        guard !calls.isEmpty else { return [] }
        var waves: [ExecutionWave] = []
        var safeBatch: [ToolCall] = []
        for call in calls {
            if firstTool(named: call.name, in: tools)?.isConcurrencySafe ?? false {
                safeBatch.append(call)
            } else {
                if !safeBatch.isEmpty {
                    waves.append(ExecutionWave(calls: safeBatch, concurrent: true))
                    safeBatch = []
                }
                waves.append(ExecutionWave(calls: [call], concurrent: false))
            }
        }
        if !safeBatch.isEmpty {
            waves.append(ExecutionWave(calls: safeBatch, concurrent: true))
        }
        return waves
    }

    private func executeConcurrentWave(
        _ calls: [ToolCall],
        context: C,
        approvalHandler: ToolApprovalHandler?
    ) async throws -> [(call: ToolCall, result: ToolResult)] {
        try await withThrowingTaskGroup(of: (Int, ToolCall, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let result = try await self.executeWithTimeout(
                        call, context: context, approvalHandler: approvalHandler
                    )
                    return (index, call, result)
                }
            }

            var results = [(Int, ToolCall, ToolResult)]()
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }

    private func executeConcurrentStreamingWave(
        _ calls: [ToolCall],
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> [(call: ToolCall, result: ToolResult)] {
        let eventFactory = options.eventFactory
        return try await withThrowingTaskGroup(of: (Int, ToolCall, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let result: ToolResult = if let streamableTool = firstTool(named: call.name, in: self.tools)
                        as? any StreamableSubAgentTool<C> {
                        try await self.executeStreamableWithTimeout(
                            call, tool: streamableTool, context: context,
                            options: options, continuation: continuation
                        )
                    } else {
                        try await self.executeWithTimeout(
                            call, context: context, approvalHandler: options.approvalHandler
                        )
                    }
                    return (index, call, result)
                }
            }

            var results = [(Int, ToolCall, ToolResult)]()
            for try await (index, call, result) in group {
                let truncated = truncatedToolResult(
                    result,
                    toolName: call.name,
                    tools: tools,
                    fallbackLimit: configuration.maxToolResultCharacters
                )
                continuation.yield(eventFactory.make(
                    .toolCallCompleted(id: call.id, name: call.name, result: truncated)
                ))
                results.append((index, call, truncated))
            }
            return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }
}

private struct ExecutionWave {
    let calls: [ToolCall]
    let concurrent: Bool
}
