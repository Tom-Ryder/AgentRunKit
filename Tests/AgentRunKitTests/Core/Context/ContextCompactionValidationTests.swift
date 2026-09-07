@testable import AgentRunKit
import Testing

struct ContextCompactionValidationTests {
    @Test(arguments: [TokenUsage(input: 10, output: 5, cacheRead: 0), nil])
    func invalidSummaryInThresholdCompactionLeavesHistoryUnchanged(summaryUsage: TokenUsage?) async throws {
        let client = CompactionMockLLMClient(
            responses: [AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_summary", name: "search", arguments: "{}")],
                tokenUsage: summaryUsage
            )],
            contextWindowSize: 1000
        )
        var compactor = ContextCompactor(
            client: client,
            configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Task"),
            .assistant(AssistantMessage(content: "Working")),
            .user("Continue"),
        ]
        let original = messages
        var usage = TokenUsageTotals()

        let outcome = try await compactor.compactOrTruncateIfNeeded(
            &messages, lastTotalTokens: 900, totalUsage: &usage
        )

        #expect(outcome == .unchanged)
        #expect(messages == original)
        #expect(await client.generateCallCount == 1)
        #expect(usage.input == (summaryUsage == nil ? 0 : 10))
        #expect(usage.output == (summaryUsage == nil ? 0 : 5))
        #expect(usage.coverage == (summaryUsage == nil ? .unavailable : .complete))
        #expect(usage.cacheRead == (summaryUsage == nil ? nil : 0))
    }

    @Test(arguments: ["", "Summary of work."])
    func summaryWithToolCallsFallsBackToTruncationAndRecordsMissingUsage(content: String) async throws {
        let client = CompactionMockLLMClient(
            responses: [AssistantMessage(
                content: content,
                toolCalls: [ToolCall(id: "call_summary", name: "search", arguments: "{}")]
            )],
            contextWindowSize: 1000
        )
        var compactor = ContextCompactor(
            client: client,
            configuration: AgentConfiguration(maxMessages: 2, compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Task"),
            .assistant(AssistantMessage(content: "Working")),
            .user("Continue"),
        ]
        var usage = TokenUsageTotals()
        usage.record(TokenUsage(input: 20, output: 10, cacheRead: 0, cacheWrite: 0))

        let outcome = try await compactor.compactOrTruncateIfNeeded(
            &messages, lastTotalTokens: 900, totalUsage: &usage
        )

        #expect(outcome == .rewritten)
        #expect(messages == [.assistant(AssistantMessage(content: "Working")), .user("Continue")])
        #expect(await client.generateCallCount == 1)
        #expect(usage.input == 20 && usage.output == 10 && usage.total == 30)
        #expect(usage.coverage == .partial)
        #expect(usage.cacheRead == 0 && usage.cacheReadCoverage == .partial)
        #expect(usage.cacheWrite == 0 && usage.cacheWriteCoverage == .partial)
    }

    @Test
    func emptyTaggedSummaryLeavesHistoryUnchangedAndRecordsUsage() async throws {
        let client = CompactionMockLLMClient(
            responses: [AssistantMessage(
                content: "<analysis>draft</analysis><summary>   </summary>",
                tokenUsage: TokenUsage(input: 8, output: 2, cacheRead: 0)
            )],
            contextWindowSize: 1000
        )
        var compactor = ContextCompactor(
            client: client, configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Task"),
            .assistant(AssistantMessage(content: "Working")),
        ]
        let original = messages
        var usage = TokenUsageTotals()

        let outcome = try await compactor.compactOrTruncateIfNeeded(
            &messages, lastTotalTokens: 900, totalUsage: &usage
        )

        #expect(outcome == .unchanged)
        #expect(messages == original)
        #expect(await client.generateCallCount == 1)
        #expect(usage.input == 8 && usage.output == 2 && usage.total == 10)
        #expect(usage.coverage == .complete)
        #expect(usage.cacheRead == 0 && usage.cacheReadCoverage == .complete)
        #expect(usage.cacheWrite == nil && usage.cacheWriteCoverage == .unavailable)
    }
}
