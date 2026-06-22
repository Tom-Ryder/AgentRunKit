@testable import AgentRunKit
import Foundation
import Testing

private let glmReasoningTrace = [
    "The user wants to know the current weather in Paris.",
    #"I'll call the get_weather function with "Paris" as the city parameter."#,
].joined(separator: " ")
private let weatherToolCall = ToolCall(id: "call_weather", name: "get_weather", arguments: #"{"city":"Paris"}"#)

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

    @Test
    func openRouterProfileEmitsReasoningDetailsAlongsideToolCalls() throws {
        let details: [JSONValue] = [
            .object([
                "type": .string("reasoning.text"),
                "format": .string("anthropic-claude-v1"),
                "index": .int(0),
                "text": .string("Let me check the weather"),
                "signature": .string("sig-abc"),
            ]),
        ]
        let toolCall = ToolCall(id: "call_123", name: "get_weather", arguments: "{\"city\":\"NYC\"}")
        let assistantMsg = AssistantMessage(
            content: "Checking",
            toolCalls: [toolCall],
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
        let encodedDetails = msg?["reasoning_details"] as? [[String: Any]]
        #expect(encodedDetails?.count == 1)
        #expect(encodedDetails?[0]["type"] as? String == "reasoning.text")
        #expect(encodedDetails?[0]["signature"] as? String == "sig-abc")
        let jsonToolCalls = msg?["tool_calls"] as? [[String: Any]]
        #expect(jsonToolCalls?.count == 1)
        #expect(jsonToolCalls?[0]["id"] as? String == "call_123")
    }

    @Test
    func reasoningContentProfileEmitsReasoningContentOnToolCallTurn() throws {
        let assistantMsg = AssistantMessage(
            content: "Checking",
            toolCalls: [weatherToolCall],
            reasoning: ReasoningContent(content: glmReasoningTrace)
        )
        let messages = try encodedMessages(
            for: [.assistant(assistantMsg)],
            assistantReplayProfile: .reasoningContent
        )
        let msg = messages[0]

        #expect(msg["reasoning_content"] as? String == glmReasoningTrace)
        #expect(msg["reasoning"] == nil)
        #expect(msg["reasoning_details"] == nil)
    }

    @Test
    func reasoningContentProfileOmitsReasoningContentOnNonToolTurn() throws {
        let assistantMsg = AssistantMessage(
            content: "Done",
            reasoning: ReasoningContent(content: glmReasoningTrace)
        )
        let messages = try encodedMessages(
            for: [.assistant(assistantMsg)],
            assistantReplayProfile: .reasoningContent
        )

        #expect(messages[0]["reasoning_content"] == nil)
    }

    @Test
    func reasoningContentProfileOmitsEmptyReasoningContent() throws {
        let assistantMsg = AssistantMessage(
            content: "Checking",
            toolCalls: [weatherToolCall],
            reasoning: ReasoningContent(content: "")
        )
        let messages = try encodedMessages(
            for: [.assistant(assistantMsg)],
            assistantReplayProfile: .reasoningContent
        )

        #expect(messages[0]["reasoning_content"] == nil)
    }

    @Test
    func reasoningContentProfileNeverEmitsReasoningDetails() throws {
        let details: [JSONValue] = [
            .object([
                "type": .string("reasoning.encrypted"),
                "encrypted": .string("base64blob=="),
            ]),
        ]
        let assistantMsg = AssistantMessage(
            content: "Checking",
            toolCalls: [weatherToolCall],
            reasoning: ReasoningContent(content: glmReasoningTrace),
            reasoningDetails: details
        )
        let messages = try encodedMessages(
            for: [.assistant(assistantMsg)],
            assistantReplayProfile: .reasoningContent
        )

        #expect(messages[0]["reasoning_details"] == nil)
        #expect(messages[0]["reasoning"] == nil)
    }

    @Test
    func reasoningContentReplaysOnEveryPriorToolCallTurnNotJustTheLast() throws {
        let firstCall = ToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Paris"}"#)
        let secondCall = ToolCall(id: "call_2", name: "get_weather", arguments: #"{"city":"Berlin"}"#)
        let messages: [ChatMessage] = [
            .user("Weather in Paris, then Berlin?"),
            .assistant(AssistantMessage(
                content: "Checking Paris",
                toolCalls: [firstCall],
                reasoning: ReasoningContent(content: "First-turn reasoning.")
            )),
            .tool(id: firstCall.id, name: firstCall.name, content: #"{"weather":"sun"}"#),
            .assistant(AssistantMessage(
                content: "Checking Berlin",
                toolCalls: [secondCall],
                reasoning: ReasoningContent(content: "Second-turn reasoning.")
            )),
            .tool(id: secondCall.id, name: secondCall.name, content: #"{"weather":"rain"}"#),
        ]

        let encoded = try encodedMessages(for: messages, assistantReplayProfile: .reasoningContent)
        let replayedReasoning = encoded.compactMap { $0["reasoning_content"] as? String }

        #expect(replayedReasoning == ["First-turn reasoning.", "Second-turn reasoning."])
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

    @Test
    func togetherFactoryPinsReplayProfileProviderURLAndProfile() throws {
        let client = OpenAIClient.together(apiKey: "test-key", model: "zai-org/GLM-5.2")

        #expect(client.modelIdentifier == "zai-org/GLM-5.2")
        #expect(client.assistantReplayProfile == .reasoningContent)
        #expect(client.providerIdentifier == .together)
        #expect(client.profile == .compatible)

        let request = try client.buildRequest(messages: [.user("Hello")], tools: [])
        let urlRequest = try client.buildURLRequest(request)
        #expect(urlRequest.url == OpenAIClient.togetherBaseURL.appendingPathComponent("chat/completions"))

        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "zai-org/GLM-5.2")
        #expect(json["max_tokens"] != nil)
        #expect(json["max_completion_tokens"] == nil)

        let chatTemplateKwargs = try #require(json["chat_template_kwargs"] as? [String: Any])
        #expect(chatTemplateKwargs["clear_thinking"] as? Bool == false)
        #expect(chatTemplateKwargs["thinking"] as? Bool == true)
    }
}

private func encodedMessages(
    for messages: [ChatMessage],
    assistantReplayProfile: OpenAIChatAssistantReplayProfile
) throws -> [[String: Any]] {
    let client = OpenAIClient(
        apiKey: "test-key",
        model: "test/model",
        baseURL: OpenAIClient.togetherBaseURL,
        assistantReplayProfile: assistantReplayProfile
    )
    let request = try client.buildRequest(messages: messages, tools: [])
    let data = try JSONEncoder().encode(request)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(json["messages"] as? [[String: Any]])
}
