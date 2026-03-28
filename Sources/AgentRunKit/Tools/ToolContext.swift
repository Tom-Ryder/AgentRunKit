/// A protocol for injecting dependencies into tool executors.
public protocol ToolContext: Sendable {
    func withParentHistory(_ history: [ChatMessage]) -> Self
}

public extension ToolContext {
    func withParentHistory(_: [ChatMessage]) -> Self {
        self
    }
}

/// A stateless ToolContext for tools that need no dependencies.
public struct EmptyContext: ToolContext {
    public init() {}
}
