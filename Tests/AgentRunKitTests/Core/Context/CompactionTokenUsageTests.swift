@testable import AgentRunKit
import Testing

private struct SummaryAccountingScenario {
    let usage: TokenUsage?
    let input: Int
    let output: Int
    let total: Int
    let cacheRead: Int
    let cacheWrite: Int
    let coverage: TokenUsageCoverage
}

private let summaryAccountingScenarios: [SummaryAccountingScenario] = [
    .init(usage: TokenUsage(input: 200, output: 300, cacheRead: 120, cacheWrite: 20),
          input: 800, output: 600, total: 1400, cacheRead: 480, cacheWrite: 70, coverage: .complete),
    .init(usage: TokenUsage(cacheRead: 0, cacheWrite: 0),
          input: 600, output: 300, total: 900, cacheRead: 360, cacheWrite: 50, coverage: .complete),
    .init(usage: nil,
          input: 600, output: 300, total: 900, cacheRead: 360, cacheWrite: 50, coverage: .partial)
]

private struct NoopParams: Codable, SchemaProviding {}
private struct NoopOutput: Codable {}

private struct CompactionTokenUsageTests {
    @Test(arguments: summaryAccountingScenarios)
    func compactionRecordsSummaryMeasurements(scenario: SummaryAccountingScenario) async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "Using tool", toolCalls: [compactionNoopCall],
                    tokenUsage: TokenUsage(input: 500, output: 250, cacheRead: 300, cacheWrite: 40)
                ),
                AssistantMessage(content: "Summary", tokenUsage: scenario.usage),
                AssistantMessage(
                    content: "", toolCalls: [ToolCall(id: "call_2", name: "finish", arguments: #"{"content":"done"}"#)],
                    tokenUsage: TokenUsage(input: 100, output: 50, cacheRead: 60, cacheWrite: 10)
                )
            ],
            contextWindowSize: 1000
        )
        let tool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "noop", description: "No-op", executor: { _, _ in NoopOutput() }
        )
        let agent = Agent(
            client: client, tools: [tool],
            configuration: AgentConfiguration(maxIterations: 5, compactionThreshold: 0.7)
        )
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())

        #expect(result.content == "done")
        #expect(result.finishReason == .completed)
        #expect(result.iterations == 2)
        #expect(await client.generateCallCount == 3)
        #expect(hasCompactionBridge(result.history))
        #expect(result.history.contains { message in
            guard case let .user(content) = message else { return false }
            return content.contains("\nSummary\n")
        })
        #expect(result.totalTokenUsage.input == scenario.input)
        #expect(result.totalTokenUsage.output == scenario.output)
        #expect(result.totalTokenUsage.reasoning == 0)
        #expect(result.totalTokenUsage.total == scenario.total)
        #expect(result.totalTokenUsage.coverage == scenario.coverage)
        #expect(result.totalTokenUsage.cacheRead == scenario.cacheRead)
        #expect(result.totalTokenUsage.cacheReadCoverage == scenario.coverage)
        #expect(result.totalTokenUsage.cacheWrite == scenario.cacheWrite)
        #expect(result.totalTokenUsage.cacheWriteCoverage == scenario.coverage)
    }
}
