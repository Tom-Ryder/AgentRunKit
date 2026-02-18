public struct SubAgentContext<C: ToolContext>: ToolContext {
    public let inner: C
    public let currentDepth: Int
    public let maxDepth: Int

    public init(inner: C, maxDepth: Int = 3, currentDepth: Int = 0) {
        precondition(maxDepth >= 1, "maxDepth must be at least 1")
        precondition(currentDepth >= 0, "currentDepth must be non-negative")
        precondition(currentDepth <= maxDepth, "currentDepth must not exceed maxDepth")
        self.inner = inner
        self.currentDepth = currentDepth
        self.maxDepth = maxDepth
    }

    public func descending() -> SubAgentContext<C> {
        SubAgentContext(inner: inner, maxDepth: maxDepth, currentDepth: currentDepth + 1)
    }
}
