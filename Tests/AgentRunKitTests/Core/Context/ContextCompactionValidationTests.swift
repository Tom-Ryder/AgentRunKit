@testable import AgentRunKit
import Testing

struct ContextCompactionValidationTests {
    @Test
    func invalidSummaryInThresholdCompactionLeavesHistoryUnchanged() async throws {
        let client = CompactionMockLLMClient(
            responses: [AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_summary", name: "search", arguments: "{}")]
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
        var usage = TokenUsage()

        let outcome = try await compactor.compactOrTruncateIfNeeded(
            &messages, lastTotalTokens: 900, totalUsage: &usage
        )

        #expect(outcome == .unchanged)
        #expect(messages == original)
        #expect(await client.generateCallCount == 1)
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
