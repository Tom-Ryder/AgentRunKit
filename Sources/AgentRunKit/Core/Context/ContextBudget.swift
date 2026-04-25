import Foundation

/// Format options for context budget annotations.
public enum ContextBudgetVisibilityFormat: Sendable, Equatable, Codable {
    case standard
    /// Replaces `{usage}` and `{window}` with grouped token counts.
    case custom(String)

    private enum CodingKeys: String, CodingKey { case type, template }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "standard":
            self = .standard
        case "custom":
            let template = try container.decode(String.self, forKey: .template)
            self = .custom(template)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown ContextBudgetVisibilityFormat type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .standard:
            try container.encode("standard", forKey: .type)
        case let .custom(template):
            try container.encode("custom", forKey: .type)
            try container.encode(template, forKey: .template)
        }
    }
}

/// A snapshot of token utilization within the context window.
public struct ContextBudget: Sendable, Equatable {
    public let windowSize: Int
    public let currentUsage: Int
    public let softThreshold: Double?

    public var utilization: Double {
        min(1.0, Double(currentUsage) / Double(windowSize))
    }

    public var remaining: Int {
        max(0, windowSize - currentUsage)
    }

    public var isAboveSoftThreshold: Bool {
        softThreshold.map { utilization >= $0 } ?? false
    }

    public init(windowSize: Int, currentUsage: Int, softThreshold: Double? = nil) {
        precondition(windowSize >= 1, "windowSize must be at least 1")
        precondition(currentUsage >= 0, "currentUsage must be non-negative")
        self.windowSize = windowSize
        self.currentUsage = currentUsage
        self.softThreshold = softThreshold
    }

    /// Renders `.standard` as `[Token usage: N / M]`, or substitutes `{usage}` and `{window}` into a custom template.
    public func formatted(_ format: ContextBudgetVisibilityFormat) -> String {
        switch format {
        case .standard:
            "[Token usage: \(Self.formatNumber(currentUsage)) / \(Self.formatNumber(windowSize))]"
        case let .custom(template):
            template
                .replacingOccurrences(of: "{usage}", with: Self.formatNumber(currentUsage))
                .replacingOccurrences(of: "{window}", with: Self.formatNumber(windowSize))
        }
    }

    private static func formatNumber(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}

extension ContextBudget: Codable {
    private enum CodingKeys: String, CodingKey {
        case windowSize, currentUsage, softThreshold
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let windowSize = try container.decode(Int.self, forKey: .windowSize)
        let currentUsage = try container.decode(Int.self, forKey: .currentUsage)
        let softThreshold = try container.decodeIfPresent(Double.self, forKey: .softThreshold)
        guard windowSize >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .windowSize, in: container,
                debugDescription: "windowSize must be >= 1, got \(windowSize)"
            )
        }
        guard currentUsage >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .currentUsage, in: container,
                debugDescription: "currentUsage must be >= 0, got \(currentUsage)"
            )
        }
        self.init(windowSize: windowSize, currentUsage: currentUsage, softThreshold: softThreshold)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowSize, forKey: .windowSize)
        try container.encode(currentUsage, forKey: .currentUsage)
        try container.encodeIfPresent(softThreshold, forKey: .softThreshold)
    }
}

/// Configuration for context budget tracking and visibility.
public struct ContextBudgetConfig: Sendable, Equatable, Codable {
    public let softThreshold: Double?
    public let enablePruneTool: Bool
    public let enableVisibility: Bool
    public let visibilityFormat: ContextBudgetVisibilityFormat

    public init(
        softThreshold: Double? = nil,
        enablePruneTool: Bool = false,
        enableVisibility: Bool = false,
        visibilityFormat: ContextBudgetVisibilityFormat = .standard
    ) {
        if let softThreshold {
            precondition(
                softThreshold > 0.0 && softThreshold < 1.0,
                "softThreshold must be in (0.0, 1.0)"
            )
        }
        self.softThreshold = softThreshold
        self.enablePruneTool = enablePruneTool
        self.enableVisibility = enableVisibility
        self.visibilityFormat = visibilityFormat
    }

    private enum CodingKeys: String, CodingKey {
        case softThreshold, enablePruneTool, enableVisibility, visibilityFormat
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let softThreshold = try container.decodeIfPresent(Double.self, forKey: .softThreshold)
        if let softThreshold {
            guard softThreshold > 0.0, softThreshold < 1.0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .softThreshold, in: container,
                    debugDescription: "softThreshold must be in (0.0, 1.0), got \(softThreshold)"
                )
            }
        }
        try self.init(
            softThreshold: softThreshold,
            enablePruneTool: container.decode(Bool.self, forKey: .enablePruneTool),
            enableVisibility: container.decode(Bool.self, forKey: .enableVisibility),
            visibilityFormat: container.decode(
                ContextBudgetVisibilityFormat.self, forKey: .visibilityFormat
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(softThreshold, forKey: .softThreshold)
        try container.encode(enablePruneTool, forKey: .enablePruneTool)
        try container.encode(enableVisibility, forKey: .enableVisibility)
        try container.encode(visibilityFormat, forKey: .visibilityFormat)
    }
}

extension ContextBudgetConfig {
    var requiresUsageTracking: Bool {
        softThreshold != nil || enableVisibility
    }
}
