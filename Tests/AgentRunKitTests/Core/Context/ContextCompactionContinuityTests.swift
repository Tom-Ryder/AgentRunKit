@testable import AgentRunKit
import Testing

struct ContextCompactionContinuityTests {
    @Test
    func compactionAcknowledgmentDoesNotInheritContinuityAndRecentAssistantKeepsIt() async throws {
        let recentContinuity = AssistantContinuity(
            substrate: .responses,
            payload: .object(["response_id": .string("resp_recent")])
        )
        let summaryContinuity = AssistantContinuity(
            substrate: .anthropicMessages,
            payload: .object([
                "thinking": .string("summary reasoning"),
                "signature": .string("sig_summary"),
            ])
        )
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "Summary of work.",
                    tokenUsage: TokenUsage(input: 50, output: 100),
                    continuity: summaryContinuity
                ),
            ],
            contextWindowSize: 1000
        )
        var compactor = ContextCompactor(
            client: client, configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(
                content: "Working state",
                toolCalls: [compactionNoopCall],
                continuity: recentContinuity
            )),
            .tool(id: "call_1", name: "noop", content: "result"),
        ]

        var usage = TokenUsageTotals()
        let outcome = try await compactor.compactOrTruncateIfNeeded(
            &messages, lastTotalTokens: 900, totalUsage: &usage
        )
        let assistants = messages.compactMap { message -> AssistantMessage? in
            guard case let .assistant(assistant) = message else { return nil }
            return assistant
        }

        #expect(outcome == .compacted)
        #expect(await client.generateCallCount == 1)
        #expect(usage.input == 50 && usage.output == 100 && usage.total == 150)
        #expect(usage.coverage == .complete)
        #expect(usage.cacheRead == nil && usage.cacheReadCoverage == .unavailable)
        #expect(usage.cacheWrite == nil && usage.cacheWriteCoverage == .unavailable)
        #expect(hasCompactionBridge(messages))
        try #require(assistants.count == 2)
        #expect(assistants[0].content == "Understood. Resuming from the checkpoint.")
        #expect(assistants[0].continuity == nil)
        #expect(assistants[1].content == "Working state")
        #expect(assistants[1].toolCalls == [compactionNoopCall])
        #expect(assistants[1].continuity == recentContinuity.droppingServerContinuationAnchor())
    }

    @Test
    func compactionDoesNotLeakRemovedAssistantContinuityIntoRewrittenHistory() async throws {
        let olderContinuity = AssistantContinuity(
            substrate: .responses,
            payload: .object(["response_id": .string("resp_old")])
        )
        let recentContinuity = AssistantContinuity(
            substrate: .anthropicMessages,
            payload: .object([
                "thinking": .string("recent reasoning"),
                "signature": .string("sig_recent"),
            ])
        )
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(
                    content: "Summary of work.",
                    tokenUsage: TokenUsage(input: 50, output: 100)
                ),
            ]
        )
        var compactor = ContextCompactor(
            client: client, configuration: AgentConfiguration(compactionThreshold: 0.5)
        )
        var messages: [ChatMessage] = [
            .user("Hello"),
            .assistant(AssistantMessage(content: "Older state", continuity: olderContinuity)),
            .assistant(AssistantMessage(
                content: "Working state",
                toolCalls: [compactionNoopCall],
                continuity: recentContinuity
            )),
            .tool(id: "call_1", name: "noop", content: "result"),
        ]

        var usage = TokenUsageTotals()
        let outcome = try await compactor.reactiveCompact(&messages, totalUsage: &usage)
        let assistants = messages.compactMap { message -> AssistantMessage? in
            guard case let .assistant(assistant) = message else { return nil }
            return assistant
        }

        #expect(outcome == .compacted)
        #expect(await client.generateCallCount == 1)
        #expect(usage.input == 50 && usage.output == 100 && usage.total == 150)
        #expect(usage.coverage == .complete)
        #expect(usage.cacheRead == nil && usage.cacheReadCoverage == .unavailable)
        #expect(usage.cacheWrite == nil && usage.cacheWriteCoverage == .unavailable)
        #expect(hasCompactionBridge(messages))
        try #require(assistants.count == 2)
        #expect(assistants[0].content == "Understood. Resuming from the checkpoint.")
        #expect(assistants[0].continuity == nil)
        #expect(assistants[1].content == "Working state")
        #expect(assistants[1].continuity == recentContinuity)
        #expect(!assistants.contains(where: { $0.continuity == olderContinuity }))
    }
}
