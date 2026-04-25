@testable import AgentRunKit
import Foundation
import Testing

private let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
private let hasAPIKey = !apiKey.isEmpty
private let model = ProcessInfo.processInfo.environment["SMOKE_OPENROUTER_MODEL"] ?? "google/gemini-3-flash-preview"

@Suite(
    .enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY environment variable"),
    .tags(.smoke, .provider, .requiresNetwork)
)
struct OpenRouterSmokeTests {
    let client = OpenAIClient.openRouter(
        apiKey: apiKey,
        model: model,
        maxTokens: 1024
    )

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "openrouter_chat",
            test: testName,
            provider: "openrouter",
            model: model,
            using: client,
            body
        )
    }

    @Test func basicGenerate() async throws {
        try await run(using: client) { client in
            try await assertSmokeGenerate(client: client)
        }
    }

    @Test func basicStream() async throws {
        try await run(using: client) { client in
            try await assertSmokeStream(client: client)
        }
    }

    @Test func toolCallRoundTrip() async throws {
        try await run(using: client) { client in
            try await assertSmokeToolCall(client: client)
        }
    }

    @Test func streamingToolCall() async throws {
        try await run(using: client) { client in
            try await assertSmokeStreamingToolCall(client: client)
        }
    }

    @Test func agentLoop() async throws {
        try await run(using: client) { client in
            try await assertSmokeAgentLoop(client: client)
        }
    }

    @Test func tokenUsagePresent() async throws {
        try await run(using: client) { client in
            try await assertSmokeTokenUsage(client: client)
        }
    }

    @Test func structuredOutput() async throws {
        try await run(using: client) { client in
            try await assertSmokeStructuredOutput(client: client)
        }
    }

    @Test func streamingAgentLoop() async throws {
        try await run(using: client) { client in
            try await assertSmokeStreamingAgentLoop(client: client)
        }
    }

    @Test func multiTurnConversation() async throws {
        try await run(using: client) { client in
            try await assertSmokeMultiTurn(client: client)
        }
    }

    @Test func streamingTokenUsage() async throws {
        try await run(using: client) { client in
            try await assertSmokeStreamingTokenUsage(client: client)
        }
    }

    @Test func chatStreamWithTools() async throws {
        try await run(using: client) { client in
            try await assertSmokeChatStreamWithTools(client: client)
        }
    }

    @Test func budgetHistoryIntegrity() async throws {
        let budgetClient = OpenAIClient.openRouter(
            apiKey: apiKey,
            model: model,
            maxTokens: 1024,
            contextWindowSize: 100
        )
        try await run(using: budgetClient) { client in
            try await assertSmokeBudgetHistoryIntegrity(client: client)
        }
    }

    @Test func nestedStructuredOutput() async throws {
        try await run(using: client) { client in
            try await assertSmokeNestedStructuredOutput(client: client)
        }
    }

    @Test func approvalGate() async throws {
        try await run(using: client) { client in
            try await assertSmokeApprovalGate(client: client)
        }
    }

    @Test func approvalDenial() async throws {
        try await run(using: client) { client in
            try await assertSmokeApprovalDenial(client: client)
        }
    }

    @Test func streamingApproval() async throws {
        try await run(using: client) { client in
            try await assertSmokeStreamingApproval(client: client)
        }
    }
}

private let reasoningModel = ProcessInfo.processInfo.environment["SMOKE_OPENROUTER_REASONING_MODEL"]
    ?? "z-ai/glm-5"

@Suite(
    .enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY"),
    .tags(.smoke, .provider, .requiresNetwork)
)
struct OpenRouterReplayPolicySmokeTests {
    let client = OpenAIClient.openRouter(
        apiKey: apiKey,
        model: reasoningModel,
        maxTokens: 4096,
        reasoningConfig: .high
    )

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "openrouter_chat_replay",
            test: testName,
            provider: "openrouter",
            model: reasoningModel,
            using: client,
            body
        )
    }

    @Test func multiTurnReasoningDetailsReplay() async throws {
        try await run(using: client) { client in
            let turn1Messages: [ChatMessage] = [
                .system("You are a helpful assistant. Think step by step."),
                .user("What is 7 * 13? Show your work."),
            ]

            let turn1 = try await client.generate(messages: turn1Messages, tools: [])
            try smokeExpect(!turn1.content.isEmpty)
            let turn1Details = try smokeRequire(
                turn1.reasoningDetails,
                "Model must return reasoning_details to exercise the replay contract"
            )
            try smokeExpect(!turn1Details.isEmpty)

            var turn2Messages = turn1Messages
            turn2Messages.append(.assistant(turn1))
            turn2Messages.append(.user("Now double that result."))

            let turn2Request = try client.buildRequest(messages: turn2Messages, tools: [])
            let encoded = try JSONEncoder().encode(turn2Request)
            let body = try smokeRequire(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                "Turn 2 request body is not a JSON object"
            )
            let messages = try smokeRequire(
                body["messages"] as? [[String: Any]],
                "Turn 2 request missing messages"
            )
            let assistantTurn = try smokeRequire(
                messages.first(where: { ($0["role"] as? String) == "assistant" }),
                "Turn 2 request missing assistant turn"
            )
            let replayedDetails = try smokeRequire(
                assistantTurn["reasoning_details"] as? [Any],
                "Turn 2 did not replay reasoning_details on the assistant turn"
            )
            try smokeExpect(replayedDetails.count == turn1Details.count)

            let turn2 = try await client.generate(messages: turn2Messages, tools: [])
            try smokeExpect(!turn2.content.isEmpty)
        }
    }
}

private let responsesModel =
    ProcessInfo.processInfo.environment["SMOKE_OPENROUTER_RESPONSES_MODEL"] ?? ""
private let hasResponsesModel = !responsesModel.isEmpty

@Suite(
    .enabled(
        if: hasAPIKey && hasResponsesModel,
        "Requires OPENROUTER_API_KEY and SMOKE_OPENROUTER_RESPONSES_MODEL"
    ),
    .tags(.smoke, .provider, .requiresNetwork)
)
struct OpenRouterResponsesSmokeTests {
    func makeClient() -> ResponsesAPIClient {
        ResponsesAPIClient(
            apiKey: apiKey,
            model: responsesModel,
            maxOutputTokens: 4096,
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: .high,
            store: false
        )
    }

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "openrouter_responses",
            test: testName,
            provider: "openrouter",
            model: responsesModel,
            using: client,
            body
        )
    }

    @Test func continuityReplay() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeResponsesContinuityReplay(client: client)
        }
    }
}
