import Foundation

func firstTool<C: ToolContext>(
    named name: String,
    in tools: [any AnyTool<C>]
) -> (any AnyTool<C>)? {
    tools.first(where: { $0.name == name })
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
