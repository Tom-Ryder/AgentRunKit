public protocol ToolContext: Sendable {}

public struct EmptyContext: ToolContext {
    public init() {}
}
