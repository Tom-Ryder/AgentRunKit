import Foundation

extension Agent {
    func tool(named name: String) -> (any AnyTool<C>)? {
        tools.first(where: { $0.name == name })
    }

    func resolveTimeout(for call: ToolCall) -> Duration? {
        guard let tool = tool(named: call.name) else {
            return configuration.toolTimeout
        }
        if let overriding = tool as? any TimeoutOverriding {
            return overriding.toolTimeout
        }
        return configuration.toolTimeout
    }

    func withTimeout<T: Sendable>(
        _ timeout: Duration?,
        toolName: String,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        guard let timeout else { return try await operation() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AgentError.toolTimeout(tool: toolName)
            }
            guard let result = try await group.next() else {
                throw AgentError.toolTimeout(tool: toolName)
            }
            group.cancelAll()
            return result
        }
    }

    func executeWithTimeout(
        _ call: ToolCall, context: C, approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> ToolResult {
        do {
            return try await withTimeout(resolveTimeout(for: call), toolName: call.name) {
                if let handler = approvalHandler,
                   let approvalAware = self.tool(named: call.name) as? any ApprovalAwareSubAgentTool<C> {
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
            return ToolResult.error("Tool failed: \(error)")
        }
    }

    func executeStreamableWithTimeout(
        _ call: ToolCall,
        tool: any StreamableSubAgentTool<C>,
        context: C,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> ToolResult {
        continuation.yield(.subAgentStarted(toolCallId: call.id, toolName: call.name))

        var result = ToolResult.error("Sub-agent did not complete")
        defer {
            continuation.yield(.subAgentCompleted(toolCallId: call.id, toolName: call.name, result: result))
        }

        let eventHandler: @Sendable (StreamEvent) -> Void = { event in
            continuation.yield(.subAgentEvent(toolCallId: call.id, toolName: call.name, event: event))
        }

        do {
            result = try await withTimeout(resolveTimeout(for: call), toolName: call.name) {
                try await tool.executeStreaming(
                    toolCallId: call.id, arguments: call.argumentsData,
                    context: context, eventHandler: eventHandler,
                    approvalHandler: approvalHandler
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentError {
            result = ToolResult.error(error.feedbackMessage)
        } catch {
            result = ToolResult.error("Tool failed: \(error)")
        }

        return result
    }

    func executeToolsStreaming(
        _ calls: [ToolCall],
        context: C,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> [(call: ToolCall, result: ToolResult)] {
        try await withThrowingTaskGroup(of: (Int, ToolCall, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let result: ToolResult = if let streamableTool = self.tool(named: call.name)
                        as? any StreamableSubAgentTool<C> {
                        try await self.executeStreamableWithTimeout(
                            call, tool: streamableTool, context: context,
                            continuation: continuation, approvalHandler: approvalHandler
                        )
                    } else {
                        try await self.executeWithTimeout(call, context: context, approvalHandler: approvalHandler)
                    }
                    return (index, call, result)
                }
            }

            var results = [(Int, ToolCall, ToolResult)]()
            for try await (index, call, result) in group {
                continuation.yield(.toolCallCompleted(id: call.id, name: call.name, result: result))
                results.append((index, call, result))
            }
            return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }

    func executeToolsInParallel(
        _ calls: [ToolCall],
        context: C,
        approvalHandler: ToolApprovalHandler? = nil
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

    func executeTool(_ call: ToolCall, context: C) async throws -> ToolResult {
        guard let tool = tool(named: call.name) else {
            throw AgentError.toolNotFound(name: call.name)
        }
        return try await tool.execute(arguments: call.argumentsData, context: context)
    }
}
