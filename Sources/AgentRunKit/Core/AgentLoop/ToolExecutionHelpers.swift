import Foundation

enum ToolFeedback {
    static let denied = "Tool call was denied."

    static func failed(_ error: any Error) -> String {
        "Tool failed: \(error)"
    }
}

func firstTool<C: ToolContext>(
    named name: String,
    in tools: [any AnyTool<C>]
) -> (any AnyTool<C>)? {
    tools.first(where: { $0.name == name })
}

func currentDepth(of context: some ToolContext) -> Int {
    (context as? any CurrentDepthProviding)?.currentDepth ?? 0
}

func truncatedToolResult<C: ToolContext>(
    _ result: ToolResult,
    toolName: String,
    tools: [any AnyTool<C>],
    fallbackLimit: Int?
) -> ToolResult {
    let limit = firstTool(named: toolName, in: tools)?.maxResultCharacters ?? fallbackLimit
    return ContextCompactor.truncateToolResult(result, maxCharacters: limit)
}

func withToolTimeout<T: Sendable>(
    _ timeout: Duration,
    toolName: String,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw AgentError.toolTimeout(tool: toolName)
        }
        guard let result = try await group.next() else {
            preconditionFailure("ThrowingTaskGroup with two tasks must yield a result")
        }
        group.cancelAll()
        return result
    }
}

struct SubAgentStreamWiring {
    let emit: StreamEmitter
    let parentSessionID: SessionID?
    let parentDepth: Int
    let historyEmissionDepthLimit: Int?

    func childEventHandler(toolCallId: String, toolName: String) -> @Sendable (StreamEvent) -> Void {
        { event in
            emit.yield(.subAgentEvent(
                toolCallId: toolCallId,
                toolName: toolName,
                event: applyHistoryEmissionLimitToSubAgentEvent(
                    event, parentDepth: parentDepth, limit: historyEmissionDepthLimit
                )
            ))
        }
    }
}

enum SubAgentDispatch {
    case blocking
    case streaming(SubAgentStreamWiring)
}

struct ToolCallRunner<C: ToolContext> {
    let context: C
    let defaultTimeout: Duration
    let approvalHandler: ToolApprovalHandler?
    let subAgentDispatch: SubAgentDispatch

    func run(_ call: ToolCall, tool: (any AnyTool<C>)?) async throws -> ToolResult {
        guard let tool else {
            return .error(AgentError.toolNotFound(name: call.name).feedbackMessage)
        }
        let timeout = tool.toolTimeout ?? defaultTimeout
        guard let subAgentTool = tool as? any SubAgentExecutableTool<C> else {
            return try await convertingToolErrors {
                try await withToolTimeout(timeout, toolName: call.name) {
                    try await tool.execute(arguments: call.argumentsData, context: context)
                }
            }
        }
        switch subAgentDispatch {
        case .blocking:
            return try await convertingToolErrors {
                try await withToolTimeout(timeout, toolName: call.name) {
                    try await subAgentTool.executeSubAgent(
                        arguments: call.argumentsData,
                        context: context,
                        approvalHandler: approvalHandler
                    )
                }
            }
        case let .streaming(wiring):
            wiring.emit.yield(.subAgentStarted(toolCallId: call.id, toolName: call.name))
            let eventHandler = wiring.childEventHandler(toolCallId: call.id, toolName: call.name)
            let result = try await convertingToolErrors {
                try await withToolTimeout(timeout, toolName: call.name) {
                    try await subAgentTool.executeSubAgentStreaming(
                        arguments: call.argumentsData,
                        context: context,
                        parentSessionID: wiring.parentSessionID,
                        eventHandler: eventHandler,
                        approvalHandler: approvalHandler
                    )
                }
            }
            wiring.emit.yield(.subAgentCompleted(toolCallId: call.id, toolName: call.name, result: result))
            return result
        }
    }
}

private func convertingToolErrors(
    _ body: () async throws -> ToolResult
) async throws -> ToolResult {
    do {
        return try await body()
    } catch let error as CancellationError {
        throw error
    } catch let error as AgentError {
        return .error(error.feedbackMessage)
    } catch {
        return .error(ToolFeedback.failed(error))
    }
}
