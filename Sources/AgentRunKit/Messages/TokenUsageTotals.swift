import Foundation

/// Accumulates reported token counts while preserving measurement availability.
public struct TokenUsageTotals: Sendable, Equatable, Codable {
    private var inputCount = 0
    private var outputCount = 0
    private var reasoningCount = 0
    private var cacheReadCount: Int? = 0
    private var cacheWriteCount: Int? = 0
    private var accounting: TokenUsageAccounting = .empty

    public var input: Int {
        inputCount
    }

    public var output: Int {
        outputCount
    }

    public var reasoning: Int {
        reasoningCount
    }

    public var cacheRead: Int? {
        cacheReadCount
    }

    public var cacheWrite: Int? {
        cacheWriteCount
    }

    public var total: Int {
        saturatingTokenSum(saturatingTokenSum(input, output), reasoning)
    }

    public var coverage: TokenUsageCoverage {
        switch accounting {
        case .empty: .complete
        case let .observed(usage, _, _): usage
        }
    }

    public var cacheReadCoverage: TokenUsageCoverage {
        switch accounting {
        case .empty: .complete
        case let .observed(_, cacheRead, _): cacheRead
        }
    }

    public var cacheWriteCoverage: TokenUsageCoverage {
        switch accounting {
        case .empty: .complete
        case let .observed(_, _, cacheWrite): cacheWrite
        }
    }

    /// Creates exact zero totals before any response has been recorded.
    public init() {}

    /// Records one returned response, retaining a measurement gap when usage is nil.
    public mutating func record(_ usage: TokenUsage?) {
        var usageCoverage: TokenUsageCoverage = usage == nil ? .unavailable : .complete
        var readCoverage: TokenUsageCoverage = usage?.cacheRead == nil ? .unavailable : .complete
        var writeCoverage: TokenUsageCoverage = usage?.cacheWrite == nil ? .unavailable : .complete
        switch accounting {
        case .empty:
            cacheReadCount = nil
            cacheWriteCount = nil
        case let .observed(previousUsage, previousRead, previousWrite):
            usageCoverage = previousUsage.combined(with: usageCoverage)
            readCoverage = previousRead.combined(with: readCoverage)
            writeCoverage = previousWrite.combined(with: writeCoverage)
        }
        accounting = .observed(usage: usageCoverage, cacheRead: readCoverage, cacheWrite: writeCoverage)
        guard let usage else { return }
        inputCount = saturatingTokenSum(inputCount, usage.input)
        outputCount = saturatingTokenSum(outputCount, usage.output)
        reasoningCount = saturatingTokenSum(reasoningCount, usage.reasoning)
        if let cacheRead = usage.cacheRead {
            cacheReadCount = saturatingTokenSum(cacheReadCount ?? 0, cacheRead)
        }
        if let cacheWrite = usage.cacheWrite {
            cacheWriteCount = saturatingTokenSum(cacheWriteCount ?? 0, cacheWrite)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case input, output, reasoning, cacheRead, cacheWrite, accounting
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputCount = try container.decodeTokenCount(forKey: .input)
        outputCount = try container.decodeTokenCount(forKey: .output)
        reasoningCount = try container.decodeTokenCount(forKey: .reasoning)
        cacheReadCount = try container.decodeTokenCountIfPresent(forKey: .cacheRead)
        cacheWriteCount = try container.decodeTokenCountIfPresent(forKey: .cacheWrite)
        if container.contains(.accounting) {
            accounting = try container.decode(TokenUsageAccounting.self, forKey: .accounting)
        } else {
            accounting = .observed(
                usage: .partial,
                cacheRead: cacheReadCount == nil ? .unavailable : .partial,
                cacheWrite: cacheWriteCount == nil ? .unavailable : .partial
            )
        }
        try validateAccounting(in: container)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputCount, forKey: .input)
        try container.encode(outputCount, forKey: .output)
        try container.encode(reasoningCount, forKey: .reasoning)
        try container.encodeIfPresent(cacheReadCount, forKey: .cacheRead)
        try container.encodeIfPresent(cacheWriteCount, forKey: .cacheWrite)
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
