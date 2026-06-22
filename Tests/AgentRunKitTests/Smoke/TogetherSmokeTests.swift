@testable import AgentRunKit
import Foundation
import Testing

private let togetherAPIKey = ProcessInfo.processInfo.environment["TOGETHER_API_KEY"] ?? ""
private let togetherHasAPIKey = !togetherAPIKey.isEmpty
private let togetherModel = ProcessInfo.processInfo.environment["SMOKE_TOGETHER_MODEL"] ?? "zai-org/GLM-5.2"

@Suite(
    .enabled(if: togetherHasAPIKey, "Requires TOGETHER_API_KEY environment variable"),
    .tags(.smoke, .provider, .requiresNetwork)
)
struct TogetherSmokeTests {
    let client = OpenAIClient.together(
        apiKey: togetherAPIKey,
        model: togetherModel,
        maxTokens: 1024
    )

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "together_chat",
            test: testName,
            provider: "together",
            model: togetherModel,
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
        let budgetClient = OpenAIClient.together(
            apiKey: togetherAPIKey,
            model: togetherModel,
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

@Suite(
    .enabled(if: togetherHasAPIKey, "Requires TOGETHER_API_KEY"),
    .tags(.smoke, .provider, .requiresNetwork)
)
struct TogetherReplayPolicySmokeTests {
    let client = OpenAIClient.together(
        apiKey: togetherAPIKey,
        model: togetherModel,
        maxTokens: 4096
    )
    let conservativeClient = OpenAIClient.together(
        apiKey: togetherAPIKey,
        model: togetherModel,
        maxTokens: 4096,
        assistantReplayProfile: .conservative
    )

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "together_chat_replay",
            test: testName,
            provider: "together",
            model: togetherModel,
            using: client,
            body
        )
    }

    @Test func multiTurnReasoningContentReplayAndConsumption() async throws {
        try await run(using: client) { client in
            let turn1Messages: [ChatMessage] = [
                .system("You are a helpful assistant. Use tools when appropriate."),
                .user("What's the current weather in Paris?"),
            ]

            let turn1 = try await client.generate(messages: turn1Messages, tools: [smokeWeatherTool])
            let toolCall = try smokeRequire(
                turn1.toolCalls.first { $0.name == "get_weather" },
                "Model must call get_weather to exercise tool-turn reasoning replay"
            )
            let reasoning = try smokeRequire(
                turn1.reasoning?.content,
                "Model must return reasoning to exercise reasoning_content replay"
            )
            try smokeExpect(!reasoning.isEmpty)

            var turn2Messages = turn1Messages
            turn2Messages.append(.assistant(turn1))
            turn2Messages.append(.tool(
                id: toolCall.id,
                name: toolCall.name,
                content: #"{"city":"Paris","weather":"sunny","unit":"celsius"}"#
            ))

            let turn2Request = try client.buildRequest(messages: turn2Messages, tools: [smokeWeatherTool])
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
            let replayedReasoning = try smokeRequire(
                assistantTurn["reasoning_content"] as? String,
                "Turn 2 did not replay reasoning_content on the assistant turn"
            )
            try smokeExpect(replayedReasoning == reasoning)

            let replayTurn2 = try await client.generate(messages: turn2Messages, tools: [smokeWeatherTool])
            try smokeExpect(!replayTurn2.content.isEmpty || !replayTurn2.toolCalls.isEmpty)

            let omitTurn2 = try await conservativeClient.generate(messages: turn2Messages, tools: [smokeWeatherTool])
            try smokeExpect(!omitTurn2.content.isEmpty || !omitTurn2.toolCalls.isEmpty)

            let replayInput = try smokeRequire(
                replayTurn2.tokenUsage?.input,
                "Reasoning-content turn 2 response missing input token usage"
            )
            let omitInput = try smokeRequire(
                omitTurn2.tokenUsage?.input,
                "Conservative turn 2 response missing input token usage"
            )
            try smokeExpect(
                replayInput > omitInput,
                "reasoning_content input tokens must exceed the omit baseline"
            )
        }
    }
}
