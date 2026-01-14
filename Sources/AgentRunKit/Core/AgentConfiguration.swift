import Foundation

public struct AgentConfiguration: Sendable, Equatable {
    public let maxIterations: Int
    public let toolTimeout: Duration
    public let systemPrompt: String?

    public init(
        maxIterations: Int = 10,
        toolTimeout: Duration = .seconds(30),
        systemPrompt: String? = nil
    ) {
        precondition(maxIterations >= 1, "maxIterations must be at least 1")
        precondition(toolTimeout >= .milliseconds(1), "toolTimeout must be at least 1ms")
        self.maxIterations = maxIterations
        self.toolTimeout = toolTimeout
        self.systemPrompt = systemPrompt
    }
}
