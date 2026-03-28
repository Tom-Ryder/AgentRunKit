import Foundation

/// Token counts for a single LLM request or accumulated across an agent run.
public struct TokenUsage: Sendable, Equatable, Codable {
    public let input: Int
    public let output: Int
    public let reasoning: Int
    public let cacheRead: Int?
    public let cacheWrite: Int?

    public var total: Int {
        saturatingAdd(saturatingAdd(input, output), reasoning)
    }

    var inputOutputTotal: Int {
        saturatingAdd(input, output)
    }

    public init(
        input: Int = 0, output: Int = 0, reasoning: Int = 0,
        cacheRead: Int? = nil, cacheWrite: Int? = nil
    ) {
        precondition(input >= 0, "input must be non-negative")
        precondition(output >= 0, "output must be non-negative")
        precondition(reasoning >= 0, "reasoning must be non-negative")
        if let cacheRead { precondition(cacheRead >= 0, "cacheRead must be non-negative") }
        if let cacheWrite { precondition(cacheWrite >= 0, "cacheWrite must be non-negative") }
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: saturatingAdd(lhs.input, rhs.input),
            output: saturatingAdd(lhs.output, rhs.output),
            reasoning: saturatingAdd(lhs.reasoning, rhs.reasoning),
            cacheRead: optionalSaturatingAdd(lhs.cacheRead, rhs.cacheRead),
            cacheWrite: optionalSaturatingAdd(lhs.cacheWrite, rhs.cacheWrite)
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}

private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : result
}

private func optionalSaturatingAdd(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case let (.some(left), .some(right)): saturatingAdd(left, right)
    case let (.some(left), .none): left
    case let (.none, .some(right)): right
    case (.none, .none): nil
    }
}
