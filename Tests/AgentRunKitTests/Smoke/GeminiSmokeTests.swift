@testable import AgentRunKit
import Foundation
import Testing

private let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
private let hasAPIKey = !apiKey.isEmpty
private let model = ProcessInfo.processInfo.environment["SMOKE_GEMINI_MODEL"] ?? "gemini-3-flash-preview"

@Suite(.enabled(if: hasAPIKey, "Requires GEMINI_API_KEY environment variable"))
struct GeminiSmokeTests {
    let client = GeminiClient(apiKey: apiKey, model: model, maxOutputTokens: 1024)

    @Test func basicGenerate() async throws {
        try await assertSmokeGenerate(client: client)
    }

    @Test func basicStream() async throws {
        try await assertSmokeStream(client: client)
    }

    @Test func toolCallRoundTrip() async throws {
        try await assertSmokeToolCall(client: client)
    }

    @Test func streamingToolCall() async throws {
        try await assertSmokeStreamingToolCall(client: client)
    }

    @Test func agentLoop() async throws {
        try await assertSmokeAgentLoop(client: client)
    }

    @Test func tokenUsagePresent() async throws {
        try await assertSmokeTokenUsage(client: client)
    }

    @Test func structuredOutput() async throws {
        try await assertSmokeStructuredOutput(client: client)
    }

    @Test func streamingAgentLoop() async throws {
        try await assertSmokeStreamingAgentLoop(client: client)
    }

    @Test func multiTurnConversation() async throws {
        try await assertSmokeMultiTurn(client: client)
    }

    @Test func streamingTokenUsage() async throws {
        try await assertSmokeStreamingTokenUsage(client: client)
    }

    @Test func chatStreamWithTools() async throws {
        try await assertSmokeChatStreamWithTools(client: client)
    }

    @Test func nestedStructuredOutput() async throws {
        try await assertSmokeNestedStructuredOutput(client: client)
    }

    @Test func reasoningStream() async throws {
        let thinkingClient = GeminiClient(
            apiKey: apiKey,
            model: model,
            maxOutputTokens: 2048,
            reasoningConfig: .medium
        )
        try await assertSmokeReasoningStream(client: thinkingClient)
    }

    @Test func reasoningGenerate() async throws {
        let thinkingClient = GeminiClient(
            apiKey: apiKey,
            model: model,
            maxOutputTokens: 2048,
            reasoningConfig: .medium
        )
        try await assertSmokeReasoningGenerate(client: thinkingClient)
    }

    @Test func approvalGate() async throws {
        try await assertSmokeApprovalGate(client: client)
    }

    @Test func approvalDenial() async throws {
        try await assertSmokeApprovalDenial(client: client)
    }

    @Test func streamingApproval() async throws {
        try await assertSmokeStreamingApproval(client: client)
    }
}
