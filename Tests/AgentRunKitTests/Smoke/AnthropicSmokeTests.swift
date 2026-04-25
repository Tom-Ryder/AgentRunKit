@testable import AgentRunKit
import Foundation
import Testing

private let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
private let hasAPIKey = !apiKey.isEmpty
private let model = ProcessInfo.processInfo.environment["SMOKE_ANTHROPIC_MODEL"] ?? "claude-sonnet-4-6"

private let cachingSystemPrompt = String(
    repeating: "You are a helpful Swift programming assistant. Follow best practices. ",
    count: 150
)

@Suite(
    .enabled(if: hasAPIKey, "Requires ANTHROPIC_API_KEY environment variable"),
    .tags(.smoke, .provider, .requiresNetwork)
)
struct AnthropicSmokeTests {
    private func makeClient() throws -> AnthropicClient {
        try AnthropicClient(apiKey: apiKey, model: model, maxTokens: 1024)
    }

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "anthropic_messages",
            test: testName,
            provider: "anthropic",
            model: model,
            using: client,
            body
        )
    }

    @Test func basicGenerate() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeGenerate(client: client)
        }
    }

    @Test func basicStream() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeStream(client: client)
        }
    }

    @Test func toolCallRoundTrip() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeToolCall(client: client)
        }
    }

    @Test func streamingToolCall() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeStreamingToolCall(client: client)
        }
    }

    @Test func agentLoop() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeAgentLoop(client: client)
        }
    }

    @Test func tokenUsagePresent() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeTokenUsage(client: client)
        }
    }

    @Test func streamingAgentLoop() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeStreamingAgentLoop(client: client)
        }
    }

    @Test func multiTurnConversation() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeMultiTurn(client: client)
        }
    }

    @Test func streamingTokenUsage() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeStreamingTokenUsage(client: client)
        }
    }

    @Test func chatStreamWithTools() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeChatStreamWithTools(client: client)
        }
    }

    @Test func budgetHistoryIntegrity() async throws {
        let budgetClient = try AnthropicClient(
            apiKey: apiKey,
            model: model,
            maxTokens: 1024,
            contextWindowSize: 100
        )
        try await run(using: budgetClient) { client in
            try await assertSmokeBudgetHistoryIntegrity(client: client)
        }
    }

    @Test func cachingEnabled() async throws {
        let cachingClient = try AnthropicClient(
            apiKey: apiKey,
            model: model,
            maxTokens: 1024,
            cachingEnabled: true
        )

        try await run(using: cachingClient) { client in
            let messages: [ChatMessage] = [
                .system(cachingSystemPrompt),
                .user("What is Swift?"),
            ]

            let response1 = try await client.generate(messages: messages, tools: [smokeWeatherTool])
            let usage1 = response1.tokenUsage
            try smokeExpect(usage1 != nil)
            try smokeExpect((usage1?.cacheWrite ?? 0) > 0)

            let response2 = try await client.generate(messages: messages, tools: [smokeWeatherTool])
            let usage2 = response2.tokenUsage
            try smokeExpect(usage2 != nil)
            try smokeExpect((usage2?.cacheRead ?? 0) > 0)
        }
    }

    @Test func nonInterleavedReasoning() async throws {
        let nonInterleavedClient = try AnthropicClient(
            apiKey: apiKey,
            model: model,
            maxTokens: 16384,
            reasoningConfig: .budget(4096),
            interleavedThinking: false
        )
        try await run(using: nonInterleavedClient) { client in
            try await assertSmokeReasoningGenerate(client: client)
        }
    }

    @Test func reasoningStream() async throws {
        let thinkingClient = try AnthropicClient(
            apiKey: apiKey,
            model: model,
            maxTokens: 16384,
            reasoningConfig: .budget(4096)
        )
        try await run(using: thinkingClient) { client in
            try await assertSmokeReasoningStream(client: client)
        }
    }

    @Test func reasoningGenerate() async throws {
        let thinkingClient = try AnthropicClient(
            apiKey: apiKey,
            model: model,
            maxTokens: 16384,
            reasoningConfig: .budget(4096)
        )
        try await run(using: thinkingClient) { client in
            try await assertSmokeReasoningGenerate(client: client)
        }
    }

    @Test func adaptiveReasoningStream() async throws {
        let thinkingClient = try AnthropicClient(
            apiKey: apiKey,
            model: model,
            maxTokens: 16384,
            reasoningConfig: .high,
            anthropicReasoning: .adaptive
        )
        try await run(using: thinkingClient) { client in
            try await assertSmokeReasoningStream(client: client)
        }
    }

    @Test func adaptiveReasoningGenerate() async throws {
        let thinkingClient = try AnthropicClient(
            apiKey: apiKey,
            model: model,
            maxTokens: 16384,
            reasoningConfig: .high,
            anthropicReasoning: .adaptive
        )
        try await run(using: thinkingClient) { client in
            try await assertSmokeReasoningGenerate(client: client)
        }
    }

    @Test func continuityReplay() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeAnthropicContinuityReplay(client: client)
        }
    }

    @Test func approvalGate() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeApprovalGate(client: client)
        }
    }

    @Test func approvalDenial() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeApprovalDenial(client: client)
        }
    }

    @Test func streamingApproval() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeStreamingApproval(client: client)
        }
    }

    @Test func structuredOutput() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeStructuredOutput(client: client)
        }
    }
}
