import Foundation

public struct ReasoningConfig: Sendable, Equatable {
    public enum Effort: String, Sendable, Codable {
        case xhigh, high, medium, low, minimal, none
    }

    public let effort: Effort
    public let maxTokens: Int?
    public let exclude: Bool?

    public init(effort: Effort, maxTokens: Int? = nil, exclude: Bool? = nil) {
        self.effort = effort
        self.maxTokens = maxTokens
        self.exclude = exclude
    }

    public static let xhigh = ReasoningConfig(effort: .xhigh)
    public static let high = ReasoningConfig(effort: .high)
    public static let medium = ReasoningConfig(effort: .medium)
    public static let low = ReasoningConfig(effort: .low)
    public static let minimal = ReasoningConfig(effort: .minimal)
    public static let none = ReasoningConfig(effort: .none)
}
