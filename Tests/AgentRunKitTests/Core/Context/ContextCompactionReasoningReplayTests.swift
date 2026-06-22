@testable import AgentRunKit
import Foundation
import Testing

struct ContextCompactionReasoningReplayTests {
    @Test
    func reasoningContentReplaySurvivesOnlyForRecentToolCallTurnsAfterCompaction() async throws {
        let client = CompactionMockLLMClient(
            responses: [
                AssistantMessage(content: "Summary.", tokenUsage: TokenUsage(input: 50, output: 100)),
            ]
        )
        let compactor = ContextCompactor(client: client, configuration: AgentConfiguration())
        let oldReasoning = "Older weather lookup reasoning."
        let recentReasoning = "Recent weather lookup reasoning."
        let oldCall = ToolCall(id: "call_old", name: "get_weather", arguments: #"{"city":"Berlin"}"#)
        let recentCall = ToolCall(id: "call_recent", name: "get_weather", arguments: #"{"city":"Paris"}"#)
        let messages: [ChatMessage] = [
            .system("You are a weather assistant."),
            .user("Check Berlin."),
            .assistant(AssistantMessage(
                content: "Checking Berlin",
                toolCalls: [oldCall],
                reasoning: ReasoningContent(content: oldReasoning)
            )),
            .tool(id: oldCall.id, name: oldCall.name, content: #"{"weather":"rain"}"#),
            .assistant(AssistantMessage(content: "Berlin is rainy.")),
            .user("Now check Paris."),
            .assistant(AssistantMessage(
                content: "Checking Paris",
                toolCalls: [recentCall],
                reasoning: ReasoningContent(content: recentReasoning)
            )),
            .tool(id: recentCall.id, name: recentCall.name, content: #"{"weather":"sun"}"#),
        ]

        let (compacted, _) = try await compactor.summarize(messages)

        #expect(hasCompactionBridge(compacted))
        #expect(!compacted.contains { message in
            if case let .assistant(assistant) = message {
                assistant.reasoning?.content == oldReasoning
            } else {
                false
            }
        })

        let openAIClient = try OpenAIClient.proxy(
            baseURL: #require(URL(string: "http://localhost:8080")),
            assistantReplayProfile: .reasoningContent
        )
        let request = try openAIClient.buildRequest(messages: compacted, tools: [])
        let data = try JSONEncoder().encode(request)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedMessages = try #require(body["messages"] as? [[String: Any]])
        let reasoningContent = encodedMessages.compactMap { $0["reasoning_content"] as? String }

        #expect(reasoningContent == [recentReasoning])
    }
}
