@testable import AgentRunKit
import Foundation
import Testing

private let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
private let hasAPIKey = !apiKey.isEmpty
private let model = ProcessInfo.processInfo.environment["SMOKE_OPENAI_RESPONSES_MODEL"] ?? "gpt-5.4-mini"

@Suite(.enabled(if: hasAPIKey, "Requires OPENAI_API_KEY environment variable"))
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

    @Test func basicGenerate() async throws {
        try await assertSmokeGenerate(client: makeClient())
    }

    @Test func basicStream() async throws {
        try await assertSmokeStream(client: makeClient())
    }

    @Test func toolCallRoundTrip() async throws {
        try await assertSmokeToolCall(client: makeClient())
    }

    @Test func streamingToolCall() async throws {
        try await assertSmokeStreamingToolCall(client: makeClient())
    }

    @Test func agentLoop() async throws {
        try await assertSmokeAgentLoop(client: makeClient())
    }

    @Test func tokenUsagePresent() async throws {
        try await assertSmokeTokenUsage(client: makeClient())
    }

    @Test func structuredOutput() async throws {
        try await assertSmokeStructuredOutput(client: makeClient())
    }

    @Test func streamingAgentLoop() async throws {
        try await assertSmokeStreamingAgentLoop(client: makeClient())
    }

    @Test func multiTurnConversation() async throws {
        try await assertSmokeMultiTurn(client: makeClient())
    }

    @Test func streamingTokenUsage() async throws {
        try await assertSmokeStreamingTokenUsage(client: makeClient())
    }

    @Test func chatStreamWithTools() async throws {
        try await assertSmokeChatStreamWithTools(client: makeClient())
    }

    @Test func nestedStructuredOutput() async throws {
        try await assertSmokeNestedStructuredOutput(client: makeClient())
    }

    @Test func conversationPersistence() async throws {
        let persistentClient = ResponsesAPIClient(
            apiKey: apiKey,
            model: model,
            maxOutputTokens: 1024,
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )
        try await assertSmokeMultiTurn(client: persistentClient)
    }

    @Test func approvalGate() async throws {
        try await assertSmokeApprovalGate(client: makeClient())
    }

    @Test func approvalDenial() async throws {
        try await assertSmokeApprovalDenial(client: makeClient())
    }

    @Test func streamingApproval() async throws {
        try await assertSmokeStreamingApproval(client: makeClient())
    }
}
