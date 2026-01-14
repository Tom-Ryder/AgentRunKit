import Foundation

public struct TokenUsage: Sendable, Equatable, Codable {
    public let input: Int
    public let output: Int
    public let reasoning: Int

    public var total: Int {
        saturatingAdd(saturatingAdd(input, output), reasoning)
    }

    public init(input: Int = 0, output: Int = 0, reasoning: Int = 0) {
        precondition(input >= 0, "input must be non-negative")
        precondition(output >= 0, "output must be non-negative")
        precondition(reasoning >= 0, "reasoning must be non-negative")
        self.input = input
        self.output = output
        self.reasoning = reasoning
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: saturatingAdd(lhs.input, rhs.input),
            output: saturatingAdd(lhs.output, rhs.output),
            reasoning: saturatingAdd(lhs.reasoning, rhs.reasoning)
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
