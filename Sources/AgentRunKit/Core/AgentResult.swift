import Foundation

/// How the agent loop terminated.
public enum FinishReason: Sendable, Equatable, CustomStringConvertible {
    case completed
    case error
    case maxIterationsReached(limit: Int)
    case tokenBudgetExceeded(budget: Int, used: Int)
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
        case let .maxIterationsReached(limit): "maxIterationsReached(limit: \(limit))"
        case let .tokenBudgetExceeded(budget, used): "tokenBudgetExceeded(budget: \(budget), used: \(used))"
        case let .custom(value): value
        }
    }

    var structuralToolErrorMessage: String? {
        switch self {
        case let .maxIterationsReached(limit):
            "Error: Agent reached maximum iterations (\(limit))."
        case let .tokenBudgetExceeded(budget, used):
            "Error: Token budget exceeded (budget: \(budget), used: \(used))."
        case .completed, .error, .custom:
            nil
        }
    }
}

extension FinishReason: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value, limit, budget, used
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "completed": self = .completed
        case "error": self = .error
        case "maxIterationsReached":
            self = try .maxIterationsReached(limit: container.decode(Int.self, forKey: .limit))
        case "tokenBudgetExceeded":
            self = try .tokenBudgetExceeded(
                budget: container.decode(Int.self, forKey: .budget),
                used: container.decode(Int.self, forKey: .used)
            )
        case "custom": self = try .custom(container.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown FinishReason type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed: try container.encode("completed", forKey: .type)
        case .error: try container.encode("error", forKey: .type)
        case let .maxIterationsReached(limit):
            try container.encode("maxIterationsReached", forKey: .type)
            try container.encode(limit, forKey: .limit)
        case let .tokenBudgetExceeded(budget, used):
            try container.encode("tokenBudgetExceeded", forKey: .type)
            try container.encode(budget, forKey: .budget)
            try container.encode(used, forKey: .used)
        case let .custom(value):
            try container.encode("custom", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct AgentResult: Sendable, Equatable {
    public let finishReason: FinishReason
    public let content: String?
    public let totalTokenUsage: TokenUsage
    public let iterations: Int
    public let history: [ChatMessage]

    public init(
        finishReason: FinishReason,
        content: String?,
        totalTokenUsage: TokenUsage,
        iterations: Int,
        history: [ChatMessage] = []
    ) {
        self.finishReason = finishReason
        self.content = content
        self.totalTokenUsage = totalTokenUsage
        self.iterations = iterations
        self.history = history
    }
}
