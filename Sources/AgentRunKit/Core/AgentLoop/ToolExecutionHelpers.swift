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
