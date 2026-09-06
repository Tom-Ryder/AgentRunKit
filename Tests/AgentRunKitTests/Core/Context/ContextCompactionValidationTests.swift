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

    @Test
    func toolCallOnlySummaryThrowsFromSummarize() async throws {
        let client = CompactionMockLLMClient(
            responses: [AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_summary", name: "search", arguments: "{}")]
            )]
        )
        let compactor = ContextCompactor(client: client, configuration: AgentConfiguration())

        await #expect(throws: AgentError.self) {
            _ = try await compactor.summarize([
                .user("Task"),
                .assistant(AssistantMessage(content: "Working")),
            ])
        }
    }

    @Test
    func emptyTaggedSummaryThrowsFromSummarize() async throws {
        let client = CompactionMockLLMClient(
            responses: [AssistantMessage(content: "<analysis>draft</analysis><summary>   </summary>")]
        )
        let compactor = ContextCompactor(client: client, configuration: AgentConfiguration())

        await #expect(throws: AgentError.self) {
            _ = try await compactor.summarize([
                .user("Task"),
                .assistant(AssistantMessage(content: "Working")),
            ])
        }
    }
}
