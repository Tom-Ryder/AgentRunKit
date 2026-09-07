@testable import AgentCode
import AgentRunKit
import Testing

private let finishedUsageCases: [(responses: [TokenUsage?], expected: String)] = [
    ([TokenUsage(input: 100, output: 20, reasoning: 5)], "completed · 125 tokens"),
    ([TokenUsage()], "completed · 0 tokens"),
    ([TokenUsage(input: 100, output: 20, reasoning: 5), nil], "completed · 125 reported tokens (partial)"),
    ([nil, TokenUsage()], "completed · 0 reported tokens (partial)"),
    ([nil, nil], "completed · usage unavailable")
]

@MainActor
struct EventRendererTests {
    @Test(arguments: finishedUsageCases)
    func finishedSummaryPreservesMeasurementCoverage(responses: [TokenUsage?], expected: String) {
        var totals = TokenUsageTotals()
        for response in responses {
            totals.record(response)
        }

        #expect(EventRenderer.finishedSummary(usage: totals, reason: .completed) == expected)
    }
}
