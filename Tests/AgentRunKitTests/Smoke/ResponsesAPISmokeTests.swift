@testable import AgentRunKit
import Foundation
import Testing

private let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
private let hasAPIKey = !apiKey.isEmpty
private let model = ProcessInfo.processInfo.environment["SMOKE_OPENAI_RESPONSES_MODEL"] ?? "gpt-5.4-mini"

@Suite(
    .enabled(if: hasAPIKey, "Requires OPENAI_API_KEY environment variable"),
    .tags(.smoke, .provider, .requiresNetwork)
)
struct ResponsesAPISmokeTests {
    func makeClient() -> ResponsesAPIClient {
        ResponsesAPIClient(
            apiKey: apiKey,
            model: model,
            maxOutputTokens: 1024,
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: false
        )
    }

    func makeBudgetClient() -> ResponsesAPIClient {
        ResponsesAPIClient(
            apiKey: apiKey,
            model: model,
            maxOutputTokens: 1024,
            contextWindowSize: 100,
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: false
        )
    }

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "openai_responses",
            test: testName,
            provider: "openai",
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

    @Test func structuredOutput() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeStructuredOutput(client: client)
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

    @Test func continuityReplay() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeResponsesContinuityReplay(client: client)
        }
    }

    @Test func finishSanitizationReplay() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeResponsesFinishSanitization(client: client)
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
        try await run(using: makeBudgetClient()) { client in
            try await assertSmokeBudgetHistoryIntegrity(client: client)
        }
    }

    @Test func nestedStructuredOutput() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeNestedStructuredOutput(client: client)
        }
    }

    @Test func conversationPersistence() async throws {
        let persistentClient = ResponsesAPIClient(
            apiKey: apiKey,
            model: model,
            maxOutputTokens: 1024,
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )
        try await run(using: persistentClient) { client in
            try await assertSmokeMultiTurn(client: client)
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
}
