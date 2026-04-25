@testable import AgentRunKit
import Foundation
import Testing

private let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
private let hasAPIKey = !apiKey.isEmpty
private let model = ProcessInfo.processInfo.environment["SMOKE_OPENROUTER_MODEL"] ?? "google/gemini-3-flash-preview"

@Suite(.enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY environment variable"), .tags(.smoke, .requiresNetwork))
struct ContextManagementSmokeTests {
    let client = OpenAIClient(
        apiKey: apiKey,
        model: model,
        maxTokens: 1024,
        baseURL: OpenAIClient.openRouterBaseURL
    )

    let budgetClient = OpenAIClient(
        apiKey: apiKey,
        model: model,
        maxTokens: 1024,
        contextWindowSize: 500,
        baseURL: OpenAIClient.openRouterBaseURL
    )

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "openrouter_context_management",
            test: testName,
            provider: "openrouter",
            model: model,
            using: client,
            body
        )
    }

    @Test func observationPruning() async throws {
        try await run(using: budgetClient) { client in
            try await assertSmokeObservationPruning(client: client)
        }
    }

    @Test func llmSummarization() async throws {
        try await run(using: budgetClient) { client in
            try await assertSmokeLLMSummarization(client: client)
        }
    }

    @Test func toolResultTruncation() async throws {
        try await run(using: client) { client in
            try await assertSmokeToolResultTruncation(client: client)
        }
    }

    @Test func maxMessages() async throws {
        try await run(using: client) { client in
            try await assertSmokeMaxMessages(client: client)
        }
    }

    @Test func budgetEvents() async throws {
        try await run(using: budgetClient) { client in
            try await assertSmokeBudgetEvents(client: client)
        }
    }

    @Test func iterationCompleted() async throws {
        try await run(using: client) { client in
            try await assertSmokeIterationCompleted(client: client)
        }
    }
}
