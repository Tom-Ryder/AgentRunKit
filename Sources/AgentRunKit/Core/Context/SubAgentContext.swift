/// Surface a current sub-agent recursion depth so emission gates (`historyEmissionDepthLimit`)
/// can apply across non-`SubAgentContext` context types adopted by external consumers.
public protocol CurrentDepthProviding {
    var currentDepth: Int { get }
}

/// A depth-tracking wrapper around a `ToolContext` for sub-agent composition.
///
/// For a guide, see <doc:SubAgents>.
public struct SubAgentContext<C: ToolContext>: ToolContext, CurrentDepthProviding {
    public let inner: C
    public let currentDepth: Int
    public let maxDepth: Int
    let parentHistory: [ChatMessage]

    public init(inner: C, maxDepth: Int = 3, currentDepth: Int = 0) {
        precondition(maxDepth >= 1, "maxDepth must be at least 1")
        precondition(currentDepth >= 0, "currentDepth must be non-negative")
        precondition(currentDepth <= maxDepth, "currentDepth must not exceed maxDepth")
        self.inner = inner
        self.currentDepth = currentDepth
        self.maxDepth = maxDepth
        parentHistory = []
    }

    private init(inner: C, maxDepth: Int, currentDepth: Int, parentHistory: [ChatMessage]) {
        self.inner = inner
        self.currentDepth = currentDepth
        self.maxDepth = maxDepth
        self.parentHistory = parentHistory
    }

    public func descending() -> SubAgentContext<C> {
        SubAgentContext(inner: inner, maxDepth: maxDepth, currentDepth: currentDepth + 1, parentHistory: [])
    }

    public func withParentHistory(_ history: [ChatMessage]) -> SubAgentContext<C> {
        SubAgentContext(inner: inner, maxDepth: maxDepth, currentDepth: currentDepth, parentHistory: history)
    }
}
