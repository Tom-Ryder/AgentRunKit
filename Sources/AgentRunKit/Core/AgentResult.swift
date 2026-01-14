import Foundation

public enum FinishReason: Sendable, Equatable, CustomStringConvertible {
    case completed
    case error
    case custom(String)

    public init(_ rawValue: String) {
        switch rawValue.lowercased() {
        case "completed": self = .completed
        case "error": self = .error
        default: self = .custom(rawValue)
        }
    }

    public var description: String {
        switch self {
        case .completed: "completed"
        case .error: "error"
        case let .custom(value): value
        }
    }
}

public struct AgentResult: Sendable, Equatable {
    public let finishReason: FinishReason
    public let content: String
    public let totalTokenUsage: TokenUsage
    public let iterations: Int

    public init(finishReason: FinishReason, content: String, totalTokenUsage: TokenUsage, iterations: Int) {
        self.finishReason = finishReason
        self.content = content
        self.totalTokenUsage = totalTokenUsage
        self.iterations = iterations
    }
}
