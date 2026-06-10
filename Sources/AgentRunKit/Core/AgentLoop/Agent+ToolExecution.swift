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

            switch try await resolveApproval(
                for: indexed.call, toolDescription: tool.description,
                handler: handler, allowlist: &allowlist, emit: emit
            ) {
            case let .approved(call):
                approved.append(IndexedToolCall(index: indexed.index, call: call))
            case let .denied(result):
                denied.append(IndexedToolResult(index: indexed.index, call: indexed.call, result: result))
            }
        }

        return (approved: approved, denied: denied)
    }

    func executeToolsStreaming(
        _ calls: [ToolCall],
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> [(call: ToolCall, result: ToolResult)] {
        let emit = StreamEmitter(factory: options.eventFactory, continuation: continuation)
        let runner = ToolCallRunner(
            context: context,
            defaultTimeout: configuration.toolTimeout,
            approvalHandler: options.approvalHandler,
            subAgentDispatch: .streaming(SubAgentStreamWiring(
                emit: emit,
                parentSessionID: options.eventFactory.sessionID,
                parentDepth: currentDepth(of: context),
                historyEmissionDepthLimit: configuration.historyEmissionDepthLimit
            ))
        )
        var allResults: [(call: ToolCall, result: ToolResult)] = []
        for wave in executionWaves(calls) {
            if wave.concurrent {
                try await allResults.append(contentsOf: executeConcurrentStreamingWave(
                    wave.calls, runner: runner, emit: emit
                ))
            } else {
                let call = wave.calls[0]
                let result = try await runner.run(call, tool: firstTool(named: call.name, in: tools))
                let truncated = truncatedToolResult(
                    result,
                    toolName: call.name,
                    tools: tools,
                    fallbackLimit: configuration.maxToolResultCharacters
                )
                emit.yield(.toolCallCompleted(id: call.id, name: call.name, result: truncated))
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
        let runner = ToolCallRunner(
            context: context,
            defaultTimeout: configuration.toolTimeout,
            approvalHandler: approvalHandler,
            subAgentDispatch: .blocking
        )
        var allResults: [(call: ToolCall, result: ToolResult)] = []
        for wave in executionWaves(calls) {
            if wave.concurrent {
                try await allResults.append(contentsOf: executeConcurrentWave(wave.calls, runner: runner))
            } else {
                let call = wave.calls[0]
                let result = try await runner.run(call, tool: firstTool(named: call.name, in: tools))
                allResults.append((call, result))
            }
        }
        return allResults
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
        runner: ToolCallRunner<C>
    ) async throws -> [(call: ToolCall, result: ToolResult)] {
        try await withThrowingTaskGroup(of: (Int, ToolCall, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let result = try await runner.run(call, tool: firstTool(named: call.name, in: self.tools))
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
        runner: ToolCallRunner<C>,
        emit: StreamEmitter
    ) async throws -> [(call: ToolCall, result: ToolResult)] {
        try await withThrowingTaskGroup(of: (Int, ToolCall, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let result = try await runner.run(call, tool: firstTool(named: call.name, in: self.tools))
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
                emit.yield(.toolCallCompleted(id: call.id, name: call.name, result: truncated))
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
