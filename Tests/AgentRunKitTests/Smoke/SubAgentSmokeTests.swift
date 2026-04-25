@testable import AgentRunKit
import Foundation
import Testing

private let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
private let hasAPIKey = !apiKey.isEmpty
private let model = ProcessInfo.processInfo.environment["SMOKE_OPENROUTER_MODEL"] ?? "google/gemini-3-flash-preview"

@Suite(.enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY environment variable"), .tags(.smoke, .requiresNetwork))
struct SubAgentSmokeTests {
    let client = OpenAIClient(
        apiKey: apiKey,
        model: model,
        maxTokens: 1024,
        baseURL: OpenAIClient.openRouterBaseURL
    )

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "openrouter_subagent",
            test: testName,
            provider: "openrouter",
            model: model,
            using: client,
            body
        )
    }

    @Test func subAgentRoundTrip() async throws {
        try await run(using: client) { client in
            try await assertSmokeSubAgentRoundTrip(client: client)
        }
    }

    @Test func subAgentStreamingEvents() async throws {
        try await run(using: client) { client in
            try await assertSmokeSubAgentStreamingEvents(client: client)
        }
    }

    @Test func subAgentHistoryInheritance() async throws {
        try await run(using: client) { client in
            try await assertSmokeSubAgentHistoryInheritance(client: client)
        }
    }
}
