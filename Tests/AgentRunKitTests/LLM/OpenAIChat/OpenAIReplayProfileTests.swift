@testable import AgentRunKit
import Foundation
import Testing

struct ReasoningMultiTurnTests {
    @Test
    func conservativeProfileOmitsReasoningContent() throws {
        let reasoning = ReasoningContent(content: "Let me think about this...")
        let assistantMsg = AssistantMessage(content: "The answer is 42", reasoning: reasoning)
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["role"] as? String == "assistant")
        #expect(msg?["content"] as? String == "The answer is 42")
        #expect(msg?["reasoning_content"] == nil)
    }

    @Test
    func conservativeProfileOmitsReasoningDetails() throws {
        let details: [JSONValue] = [
            .object([
                "type": .string("reasoning.encrypted"),
                "encrypted": .string("base64blob=="),
                "id": .string("re_001"),
            ]),
        ]
        let assistantMsg = AssistantMessage(content: "Result", reasoningDetails: details)
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["reasoning_details"] == nil)
    }

    @Test
    func openRouterProfileEmitsReasoningDetails() throws {
        let details: [JSONValue] = [
            .object([
                "type": .string("reasoning.encrypted"),
                "encrypted": .string("base64blob=="),
                "id": .string("re_001"),
            ]),
        ]
        let assistantMsg = AssistantMessage(content: "Result", reasoningDetails: details)
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL,
            assistantReplayProfile: .openRouterReasoningDetails
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        let encodedDetails = msg?["reasoning_details"] as? [[String: Any]]
        #expect(encodedDetails?.count == 1)
        #expect(encodedDetails?[0]["type"] as? String == "reasoning.encrypted")
        #expect(encodedDetails?[0]["encrypted"] as? String == "base64blob==")
        #expect(encodedDetails?[0]["id"] as? String == "re_001")
    }

    @Test
    func openRouterProfileStillOmitsReasoningContent() throws {
        let reasoning = ReasoningContent(content: "I need to check the weather...")
        let details: [JSONValue] = [
            .object(["type": .string("reasoning.encrypted"), "encrypted": .string("blob==")]),
        ]
        let assistantMsg = AssistantMessage(
            content: "Result",
            reasoning: reasoning,
            reasoningDetails: details
        )
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL,
            assistantReplayProfile: .openRouterReasoningDetails
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["reasoning_content"] == nil)
        #expect(msg?["reasoning_details"] != nil)
    }

    @Test
    func baseURLAloneDoesNotChangeReplayBehavior() throws {
        let details: [JSONValue] = [
            .object(["type": .string("reasoning.encrypted"), "encrypted": .string("blob==")]),
        ]
        let assistantMsg = AssistantMessage(content: "Result", reasoningDetails: details)
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(
            msg?["reasoning_details"] == nil,
            "OpenRouter baseURL without explicit profile must not emit reasoning_details"
        )
    }

    @Test
    func assistantMessageWithoutReasoningDetailsOmitsField() throws {
        let assistantMsg = AssistantMessage(content: "Simple")
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL,
            assistantReplayProfile: .openRouterReasoningDetails
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["reasoning_details"] == nil)
    }

    @Test
    func reasoningDetailsRoundTripPreservesSnakeCaseKeys() throws {
        let details: [JSONValue] = [
            .object([
                "type": .string("reasoning.text"),
                "reasoning_type": .string("chain_of_thought"),
                "inner_data": .object(["nested_key": .string("value")]),
            ]),
        ]
        let assistantMsg = AssistantMessage(content: "Result", reasoningDetails: details)
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL,
            assistantReplayProfile: .openRouterReasoningDetails
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        let encodedDetails = msg?["reasoning_details"] as? [[String: Any]]
        let obj = encodedDetails?[0]
        #expect(obj?["reasoning_type"] as? String == "chain_of_thought")
        let inner = obj?["inner_data"] as? [String: Any]
        #expect(inner?["nested_key"] as? String == "value")
        #expect(obj?["reasoningType"] == nil, "snake_case keys must survive the round-trip unchanged")
    }

    @Test
    func conservativeProfileWithToolCallsOmitsReasoning() throws {
        let reasoning = ReasoningContent(content: "I need to check the weather...")
        let toolCall = ToolCall(id: "call_123", name: "get_weather", arguments: "{\"city\":\"NYC\"}")
        let assistantMsg = AssistantMessage(
            content: "Let me check",
            toolCalls: [toolCall],
            reasoning: reasoning
        )
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["reasoning_content"] == nil)
        let jsonToolCalls = msg?["tool_calls"] as? [[String: Any]]
        #expect(jsonToolCalls?.count == 1)
    }
}

struct ReplayProfileDefaultTests {
    @Test
    func publicInitializerDefaultsToConservative() {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openAIBaseURL
        )
        #expect(client.assistantReplayProfile == .conservative)
    }

    @Test
    func proxyDefaultsToConservative() throws {
        let client = try OpenAIClient.proxy(
            baseURL: #require(URL(string: "http://localhost:8080"))
        )
        #expect(client.assistantReplayProfile == .conservative)
    }

    @Test
    func proxyPassesThroughExplicitProfile() throws {
        let client = try OpenAIClient.proxy(
            baseURL: #require(URL(string: "http://localhost:8080")),
            assistantReplayProfile: .openRouterReasoningDetails
        )
        #expect(client.assistantReplayProfile == .openRouterReasoningDetails)
    }

    @Test
    func genericProxyWithDefaultProfileOmitsBothFields() throws {
        let reasoning = ReasoningContent(content: "thinking...")
        let details: [JSONValue] = [
            .object(["type": .string("reasoning.encrypted"), "encrypted": .string("blob==")]),
        ]
        let assistantMsg = AssistantMessage(
            content: "Result",
            reasoning: reasoning,
            reasoningDetails: details
        )
        let client = try OpenAIClient.proxy(
            baseURL: #require(URL(string: "http://localhost:8080"))
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["reasoning_content"] == nil)
        #expect(msg?["reasoning_details"] == nil)
    }
}
