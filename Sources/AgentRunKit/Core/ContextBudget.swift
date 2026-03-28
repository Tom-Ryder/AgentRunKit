import Foundation

/// Format options for context budget annotations.
public enum ContextBudgetVisibilityFormat: Sendable, Equatable {
    case standard
    /// Replaces `{usage}` and `{window}` with grouped token counts.
    case custom(String)
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

    /// Formats the budget as a display string.
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

/// Configuration for context budget tracking and visibility.
public struct ContextBudgetConfig: Sendable, Equatable {
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
}

extension ContextBudgetConfig {
    var requiresUsageTracking: Bool {
        softThreshold != nil || enableVisibility
    }
}
