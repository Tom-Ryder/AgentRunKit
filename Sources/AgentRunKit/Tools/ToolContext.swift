public protocol ToolContext: Sendable {
    func withParentHistory(_ history: [ChatMessage]) -> Self
}

public extension ToolContext {
    func withParentHistory(_: [ChatMessage]) -> Self { self }
}

public struct EmptyContext: ToolContext {
    public init() {}
}
