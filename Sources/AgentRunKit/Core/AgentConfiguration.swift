import Foundation

/// Configuration for the agent loop.
///
/// For a guide, see <doc:AgentAndChat>.
public struct AgentConfiguration: Sendable, Equatable {
    public let maxIterations: Int
    public let toolTimeout: Duration
    public let systemPrompt: String?
    public let maxMessages: Int?
    public let compactionThreshold: Double?
    public let compactionPrompt: String?
    public let maxToolResultCharacters: Int?
    public let contextBudget: ContextBudgetConfig?

    public init(
        maxIterations: Int = 10,
        toolTimeout: Duration = .seconds(30),
        systemPrompt: String? = nil,
        maxMessages: Int? = nil,
        compactionThreshold: Double? = nil,
        compactionPrompt: String? = nil,
        maxToolResultCharacters: Int? = nil,
        contextBudget: ContextBudgetConfig? = nil
    ) {
        precondition(maxIterations >= 1, "maxIterations must be at least 1")
        precondition(toolTimeout >= .milliseconds(1), "toolTimeout must be at least 1ms")
        if let maxMessages {
            precondition(maxMessages >= 1, "maxMessages must be at least 1")
        }
        if let compactionThreshold {
            precondition(
                compactionThreshold > 0.0 && compactionThreshold < 1.0,
                "compactionThreshold must be in (0.0, 1.0)"
            )
        }
        if let maxToolResultCharacters {
            precondition(maxToolResultCharacters >= 1, "maxToolResultCharacters must be at least 1")
        }
        self.maxIterations = maxIterations
        self.toolTimeout = toolTimeout
        self.systemPrompt = systemPrompt
        self.maxMessages = maxMessages
        self.compactionThreshold = compactionThreshold
        self.compactionPrompt = compactionPrompt
        self.maxToolResultCharacters = maxToolResultCharacters
        self.contextBudget = contextBudget
    }
}
