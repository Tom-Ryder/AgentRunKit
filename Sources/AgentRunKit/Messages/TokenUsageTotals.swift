import Foundation

/// Accumulates reported token counts while preserving measurement availability.
///
/// For coverage and saturation semantics, see <doc:TokenAccounting>.
public struct TokenUsageTotals: Sendable, Equatable, Codable {
    /// The reported input subtotal, including reported cache reads and writes.
    public private(set) var input: Int = 0
    /// The reported output subtotal, excluding separately reported reasoning.
    public private(set) var output: Int = 0
    /// The subtotal of separately reported reasoning tokens.
    public private(set) var reasoning: Int = 0
    /// The cache-read subtotal, including measured zero, or nil when its coverage is unavailable.
    public private(set) var cacheRead: Int? = 0
    /// The cache-write subtotal, including measured zero, or nil when its coverage is unavailable.
    public private(set) var cacheWrite: Int? = 0

    /// The sum of input, output, and reasoning, saturated at Int.max.
    public var total: Int {
        saturatingTokenSum(saturatingTokenSum(input, output), reasoning)
    }

    /// Measurement availability across recorded responses, independent of separate reasoning breakdowns.
    public var coverage: TokenUsageCoverage {
        switch accounting {
        case .empty: .complete
        case let .observed(usage, _, _): usage
        }
    }

    /// Measurement availability for cache reads, tracked independently of cache writes.
    public var cacheReadCoverage: TokenUsageCoverage {
        switch accounting {
        case .empty: .complete
        case let .observed(_, cacheRead, _): cacheRead
        }
    }

    /// Measurement availability for cache writes, tracked independently of cache reads.
    public var cacheWriteCoverage: TokenUsageCoverage {
        switch accounting {
        case .empty: .complete
        case let .observed(_, _, cacheWrite): cacheWrite
        }
    }

    private var accounting: TokenUsageAccounting = .empty

    /// Creates exact zero totals before any response has been recorded.
    public init() {}

    /// Records one returned response, retaining a measurement gap when usage is nil.
    public mutating func record(_ usage: TokenUsage?) {
        var usageCoverage: TokenUsageCoverage = usage == nil ? .unavailable : .complete
        var readCoverage: TokenUsageCoverage = usage?.cacheRead == nil ? .unavailable : .complete
        var writeCoverage: TokenUsageCoverage = usage?.cacheWrite == nil ? .unavailable : .complete
        switch accounting {
        case .empty:
            cacheRead = nil
            cacheWrite = nil
        case let .observed(previousUsage, previousRead, previousWrite):
            usageCoverage = previousUsage.combined(with: usageCoverage)
            readCoverage = previousRead.combined(with: readCoverage)
            writeCoverage = previousWrite.combined(with: writeCoverage)
        }
        accounting = .observed(usage: usageCoverage, cacheRead: readCoverage, cacheWrite: writeCoverage)
        guard let usage else { return }
        input = saturatingTokenSum(input, usage.input)
        output = saturatingTokenSum(output, usage.output)
        reasoning = saturatingTokenSum(reasoning, usage.reasoning)
        if let cacheRead = usage.cacheRead {
            self.cacheRead = saturatingTokenSum(self.cacheRead ?? 0, cacheRead)
        }
        if let cacheWrite = usage.cacheWrite {
            self.cacheWrite = saturatingTokenSum(self.cacheWrite ?? 0, cacheWrite)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case input, output, reasoning, cacheRead, cacheWrite, accounting
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeTokenCount(forKey: .input)
        output = try container.decodeTokenCount(forKey: .output)
        reasoning = try container.decodeTokenCount(forKey: .reasoning)
        cacheRead = try container.decodeTokenCountIfPresent(forKey: .cacheRead)
        cacheWrite = try container.decodeTokenCountIfPresent(forKey: .cacheWrite)
        if container.contains(.accounting) {
            accounting = try container.decode(TokenUsageAccounting.self, forKey: .accounting)
        } else {
            accounting = .observed(
                usage: .partial,
                cacheRead: cacheRead == nil ? .unavailable : .partial,
                cacheWrite: cacheWrite == nil ? .unavailable : .partial
            )
        }
        try validateAccounting(in: container)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encode(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(cacheRead, forKey: .cacheRead)
        try container.encodeIfPresent(cacheWrite, forKey: .cacheWrite)
        try container.encode(accounting, forKey: .accounting)
    }

    private func validateAccounting(in container: KeyedDecodingContainer<CodingKeys>) throws {
        switch accounting {
        case .empty:
            guard input == 0, output == 0, reasoning == 0, cacheRead == 0, cacheWrite == 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .accounting, in: container,
                    debugDescription: "Empty accounting requires all five token counts to be zero"
                )
            }
        case let .observed(usage, read, write):
            if usage == .unavailable {
                guard input == 0, output == 0, reasoning == 0, read == .unavailable, write == .unavailable else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .accounting, in: container,
                        debugDescription: "Unavailable usage requires zero scalar counts and unavailable cache coverage"
                    )
                }
            }
            try validateCache(cacheRead, coverage: read, forKey: .cacheRead, in: container)
            try validateCache(cacheWrite, coverage: write, forKey: .cacheWrite, in: container)
        }
    }

    private func validateCache(
        _ value: Int?, coverage cacheCoverage: TokenUsageCoverage,
        forKey key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard (value != nil) == (cacheCoverage != .unavailable) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "\(key.stringValue) requires a value exactly when its coverage is partial or complete"
            )
        }
        guard cacheCoverage != .complete || coverage == .complete else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "Complete \(key.stringValue) coverage requires complete usage coverage"
            )
        }
    }
}

private enum TokenUsageAccounting: Equatable, Codable {
    case empty
    case observed(usage: TokenUsageCoverage, cacheRead: TokenUsageCoverage, cacheWrite: TokenUsageCoverage)

    private enum CodingKeys: String, CodingKey {
        case type, usage, cacheRead, cacheWrite
    }

    private enum Kind: String, Codable {
        case empty, observed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .empty:
            self = .empty
        case .observed:
            self = try .observed(
                usage: container.decode(TokenUsageCoverage.self, forKey: .usage),
                cacheRead: container.decode(TokenUsageCoverage.self, forKey: .cacheRead),
                cacheWrite: container.decode(TokenUsageCoverage.self, forKey: .cacheWrite)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty:
            try container.encode(Kind.empty, forKey: .type)
        case let .observed(usage, cacheRead, cacheWrite):
            try container.encode(Kind.observed, forKey: .type)
            try container.encode(usage, forKey: .usage)
            try container.encode(cacheRead, forKey: .cacheRead)
            try container.encode(cacheWrite, forKey: .cacheWrite)
        }
    }
}

private extension TokenUsageCoverage {
    func combined(with other: TokenUsageCoverage) -> TokenUsageCoverage {
        switch (self, other) {
        case (.complete, .complete): .complete
        case (.unavailable, .unavailable): .unavailable
        default: .partial
        }
    }
}
