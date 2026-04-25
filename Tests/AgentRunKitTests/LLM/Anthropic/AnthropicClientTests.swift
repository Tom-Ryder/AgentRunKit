@testable import AgentRunKit
import Foundation
import Testing

private func encodeRequest(_ request: AnthropicRequest) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
    guard let dict = object as? [String: Any] else {
        preconditionFailure("Encoded request is not a JSON object: \(object)")
    }
    return dict
}

struct AnthropicRequestSerializationTests {
    private func makeClient(
        model: String = "claude-sonnet-4-6",
        reasoningConfig: ReasoningConfig? = nil,
        anthropicReasoning: AnthropicReasoningOptions = .manual,
        interleavedThinking: Bool = false,
        maxTokens: Int = 8192
    ) throws -> AnthropicClient {
        try AnthropicClient(
            apiKey: "test-key",
            model: model,
            maxTokens: maxTokens,
            reasoningConfig: reasoningConfig,
            anthropicReasoning: anthropicReasoning,
            interleavedThinking: interleavedThinking
        )
    }

    @Test
    func userMessageMapsCorrectly() throws {
        let client = try makeClient()
        let request = try client.buildRequest(messages: [.user("Hello")], tools: [])
        let json = try encodeRequest(request)

        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?[0]["role"] as? String == "user")
        #expect(messages?[0]["content"] as? String == "Hello")
    }

    @Test
    func systemMessageExtractedToTopLevel() throws {
        let client = try makeClient()
        let messages: [ChatMessage] = [.system("Be helpful"), .user("Hi")]
        let request = try client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let system = json["system"] as? [[String: Any]]
        #expect(system?.count == 1)
        #expect(system?[0]["type"] as? String == "text")
        #expect(system?[0]["text"] as? String == "Be helpful")

        let msgs = json["messages"] as? [[String: Any]]
        #expect(msgs?.count == 1)
        #expect(msgs?[0]["role"] as? String == "user")
    }

    @Test
    func multipleSystemMessages() throws {
        let client = try makeClient()
        let messages: [ChatMessage] = [.system("First"), .system("Second"), .user("Hi")]
        let request = try client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let system = json["system"] as? [[String: Any]]
        #expect(system?.count == 2)
        #expect(system?[0]["text"] as? String == "First")
        #expect(system?[1]["text"] as? String == "Second")
    }

    @Test
    func noSystemOmitsField() throws {
        let client = try makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["system"] == nil)
    }

    @Test
    func toolDefinitionsEncode() throws {
        let client = try makeClient()
        let tools = [
            ToolDefinition(
                name: "get_weather",
                description: "Get weather",
                parametersSchema: .object(properties: ["city": .string()], required: ["city"])
            )
        ]
        let request = try client.buildRequest(messages: [.user("Hi")], tools: tools)
        let json = try encodeRequest(request)

        let jsonTools = json["tools"] as? [[String: Any]]
        #expect(jsonTools?.count == 1)
        #expect(jsonTools?[0]["name"] as? String == "get_weather")
        #expect(jsonTools?[0]["description"] as? String == "Get weather")
        let schema = jsonTools?[0]["input_schema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object")
        let props = schema?["properties"] as? [String: Any]
        let cityProp = props?["city"] as? [String: Any]
        #expect(cityProp?["type"] as? String == "string")
        #expect(schema?["required"] as? [String] == ["city"])
    }

    @Test
    func strictTrueThrowsFeatureUnsupported() throws {
        let client = try makeClient()
        let tools = [
            ToolDefinition(
                name: "strict_true",
                description: "",
                parametersSchema: .object(properties: [:], required: []),
                strict: true
            )
        ]
        #expect {
            _ = try client.buildRequest(messages: [.user("hi")], tools: tools)
        } throws: { error in
            guard case let AgentError.llmError(inner) = error,
                  case let .featureUnsupported(provider, feature) = inner
            else { return false }
            return provider == "anthropic" && feature == "strict function schemas"
        }
    }

    @Test
    func strictFalseAndNilOmitWireField() throws {
        let client = try makeClient()
        let tools = [
            ToolDefinition(
                name: "strict_false",
                description: "",
                parametersSchema: .object(properties: [:], required: []),
                strict: false
            ),
            ToolDefinition(
                name: "strict_nil",
                description: "",
                parametersSchema: .object(properties: [:], required: [])
            )
        ]
        let request = try client.buildRequest(messages: [.user("hi")], tools: tools)
        let json = try encodeRequest(request)
        let jsonTools = try #require(json["tools"] as? [[String: Any]])
        #expect(jsonTools.count == 2)
        for tool in jsonTools {
            #expect(tool["strict"] == nil, "Anthropic tool wire body must omit 'strict': \(tool)")
        }
    }

    @Test
    func emptyToolsOmitsField() throws {
        let client = try makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["tools"] == nil)
    }

    @Test
    func maxTokensEncodes() throws {
        let client = try makeClient(maxTokens: 4096)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["max_tokens"] as? Int == 4096)
    }

    @Test
    func streamFlagEncodes() throws {
        let client = try makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [], stream: true)
        let json = try encodeRequest(request)

        #expect(json["stream"] as? Bool == true)
    }

    @Test
    func streamFlagOmittedWhenFalse() throws {
        let client = try makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["stream"] == nil)
    }

    @Test
    func manualThinkingConfigEncodes() throws {
        let client = try makeClient(reasoningConfig: .high, maxTokens: 65536)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let thinking = json["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["budget_tokens"] as? Int == 16384)
        #expect(json["output_config"] == nil)
    }

    @Test
    func adaptiveThinkingEncodes() throws {
        let client = try makeClient(
            reasoningConfig: .high,
            anthropicReasoning: .adaptive
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let thinking = json["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "adaptive")

        let outputConfig = json["output_config"] as? [String: Any]
        #expect(outputConfig?["effort"] as? String == "high")
    }

    @Test
    func thinkingDisabledForNoneEffort() throws {
        let client = try makeClient(reasoningConfig: ReasoningConfig.none)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let thinking = json["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "disabled")
    }

    @Test
    func noReasoningOmitsThinking() throws {
        let client = try makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["thinking"] == nil)
    }

    @Test
    func validExtraFieldsEncode() throws {
        let client = try makeClient()
        let request = try client.buildRequest(
            messages: [.user("Hi")], tools: [],
            extraFields: ["temperature": .double(0.7), "top_p": .double(0.9)]
        )
        let json = try encodeRequest(request)

        #expect(json["temperature"] as? Double == 0.7)
        #expect(json["top_p"] as? Double == 0.9)
    }

    @Test
    func invalidExtraFieldThrows() throws {
        let client = try makeClient()
        let request = try client.buildRequest(
            messages: [.user("Hi")], tools: [],
            extraFields: ["bad_field": .string("nope")]
        )
        do {
            _ = try JSONEncoder().encode(request)
            Issue.record("Expected EncodingError")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(context.debugDescription.contains("bad_field"))
        } catch {
            Issue.record("Expected EncodingError.invalidValue, got \(error)")
        }
    }

    @Test
    func modelFieldEncodes() throws {
        let client = try makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["model"] as? String == "claude-sonnet-4-6")
    }

    @Test
    func adaptiveThinkingRejectsExplicitBudgetTokens() throws {
        let client = try makeClient(
            reasoningConfig: .budget(4096),
            anthropicReasoning: .adaptive
        )

        #expect(throws: AgentError.self) {
            _ = try client.buildRequest(messages: [.user("Hi")], tools: [])
        }
    }

    @Test
    func adaptiveThinkingRejectsMinimalEffort() throws {
        let client = try makeClient(
            reasoningConfig: .minimal,
            anthropicReasoning: .adaptive
        )

        #expect(throws: AgentError.self) {
            _ = try client.buildRequest(messages: [.user("Hi")], tools: [])
        }
    }

    @Test
    func adaptiveThinkingRejectsKnownUnsupportedModel() {
        #expect(throws: AgentError.self) {
            _ = try AnthropicClient(
                apiKey: "test-key",
                model: "claude-opus-4-5-20251101",
                reasoningConfig: .high,
                anthropicReasoning: .adaptive
            )
        }
    }
}

struct AnthropicURLRequestTests {
    @Test
    func setsCorrectHeaders() throws {
        let client = try AnthropicClient(
            apiKey: "sk-ant-test-123",
            model: "claude-sonnet-4-6"
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-123")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test
    func betaHeaderWhenInterleavedThinking() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            reasoningConfig: .high,
            interleavedThinking: true
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "interleaved-thinking-2025-05-14")
    }

    @Test
    func adaptiveThinkingDoesNotSendBetaHeader() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            reasoningConfig: .high,
            anthropicReasoning: .adaptive,
            interleavedThinking: true
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test
    func noBetaHeaderWithoutInterleavedThinking() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            reasoningConfig: .high,
            interleavedThinking: false
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test
    func noBetaHeaderWithoutReasoning() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            interleavedThinking: true
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test
    func customBaseURL() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            baseURL: #require(URL(string: "https://custom.api.example.com/v2"))
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://custom.api.example.com/v2/messages")
    }

    @Test
    func additionalHeadersApplied() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            additionalHeaders: { ["X-Custom": "value123", "x-api-key": "fake"] }
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "X-Custom") == "value123")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "test-key")
    }

    @Test
    func existingAnthropicBetaHeaderIsMerged() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            additionalHeaders: { ["anthropic-beta": "files-api-2025-04-14"] },
            reasoningConfig: .high,
            interleavedThinking: true
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(
            urlRequest.value(forHTTPHeaderField: "anthropic-beta")
                == "files-api-2025-04-14,interleaved-thinking-2025-05-14"
        )
    }

    @Test
    func manualInterleavedThinkingOnOpus46_docsSayIgnoredAccepts() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-opus-4-6",
            reasoningConfig: .high,
            interleavedThinking: true
        )
        // Per docs: Opus 4.6 direct manual+interleaved is deprecated but the beta
        // header is ignored server-side, so the request must not throw.
        _ = try client.buildRequest(messages: [.user("Hi")], tools: [])
    }
}

struct AnthropicBudgetMappingTests {
    @Test
    func effortMappingValues() throws {
        let efforts: [(ReasoningConfig.Effort, Int)] = [
            (.xhigh, 32768), (.high, 16384), (.medium, 8192),
            (.low, 4096), (.minimal, 1024)
        ]
        for (effort, expected) in efforts {
            let client = try AnthropicClient(
                apiKey: "k", model: "claude-opus-4-5", maxTokens: 65536,
                reasoningConfig: ReasoningConfig(effort: effort)
            )
            let thinking = try client.buildManualThinkingConfig(ReasoningConfig(effort: effort))
            guard case .enabled = thinking else {
                Issue.record("Expected thinking config for \(effort)")
                continue
            }
            #expect(thinking.budgetTokens == expected)
        }
    }

    @Test
    func budgetFlooredTo1024() throws {
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-opus-4-5", maxTokens: 65536,
            reasoningConfig: .budget(500)
        )
        let config = try client.buildManualThinkingConfig(.budget(500))
        #expect(config.budgetTokens == 1024)
    }

    @Test
    func budgetCappedToMaxTokensMinusOne() throws {
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-opus-4-5", maxTokens: 2048,
            reasoningConfig: .budget(4096),
            interleavedThinking: false
        )
        let config = try client.buildManualThinkingConfig(.budget(4096))
        #expect(config.budgetTokens == 2047)
    }

    @Test
    func interleavedSkipsCap() throws {
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-opus-4-5", maxTokens: 2048,
            reasoningConfig: .budget(4096)
        )
        let config = try client.buildManualThinkingConfig(.budget(4096))
        #expect(config.budgetTokens == 4096)
    }

    @Test
    func budgetBelowFloorAfterCapThrows() throws {
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-opus-4-5", maxTokens: 1024,
            reasoningConfig: .budget(2048),
            interleavedThinking: false
        )
        #expect(throws: AgentError.self) {
            _ = try client.buildManualThinkingConfig(.budget(2048))
        }
    }

    @Test
    func explicitBudgetTokensUsed() throws {
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-opus-4-5", maxTokens: 65536,
            reasoningConfig: .budget(10000)
        )
        let config = try client.buildManualThinkingConfig(.budget(10000))
        #expect(config.budgetTokens == 10000)
    }

    @Test
    func noneEffortWithExplicitBudgetUsesBudget() throws {
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-opus-4-5", maxTokens: 65536,
            reasoningConfig: ReasoningConfig(effort: .none, budgetTokens: 4096)
        )
        let config = try client.buildManualThinkingConfig(
            ReasoningConfig(effort: .none, budgetTokens: 4096)
        )
        #expect(config.budgetTokens == 4096)
    }
}

struct AnthropicCachingRequestTests {
    private let testTools = [
        ToolDefinition(
            name: "search", description: "Search",
            parametersSchema: .object(properties: ["q": .string()], required: ["q"])
        ),
        ToolDefinition(
            name: "lookup", description: "Lookup",
            parametersSchema: .object(properties: ["id": .integer()], required: ["id"])
        ),
    ]

    @Test
    func cachingDisabledOmitsCacheControl() throws {
        let client = try AnthropicClient(apiKey: "k", model: "m", cachingEnabled: false)
        let request = try client.buildRequest(
            messages: [.system("Be helpful"), .user("Hi")],
            tools: testTools
        )
        let json = try encodeRequest(request)

        let system = json["system"] as? [[String: Any]]
        #expect(system?.last?["cache_control"] == nil)

        let tools = json["tools"] as? [[String: Any]]
        #expect(tools?.last?["cache_control"] == nil)
    }

    @Test
    func cachingEnabledMarksLastSystemBlock() throws {
        let client = try AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
        let request = try client.buildRequest(
            messages: [.system("First"), .system("Second"), .user("Hi")],
            tools: []
        )
        let json = try encodeRequest(request)

        let system = json["system"] as? [[String: Any]]
        #expect(system?.count == 2)
        #expect(system?[0]["cache_control"] == nil)
        let lastCC = system?[1]["cache_control"] as? [String: Any]
        #expect(lastCC?["type"] as? String == "ephemeral")
    }

    @Test
    func cachingEnabledMarksLastToolDefinition() throws {
        let client = try AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: testTools
        )
        let json = try encodeRequest(request)

        let tools = json["tools"] as? [[String: Any]]
        #expect(tools?.count == 2)
        #expect(tools?[0]["cache_control"] == nil)
        let lastCC = tools?[1]["cache_control"] as? [String: Any]
        #expect(lastCC?["type"] as? String == "ephemeral")
    }

    @Test
    func cachingWithNoSystemOrTools() throws {
        let client = try AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: []
        )
        let json = try encodeRequest(request)
        #expect(json["system"] == nil)
        #expect(json["tools"] == nil)
    }
}

struct AnthropicConversationCachingTests {
    @Test
    func conversationCachingMarksSecondToLastUserMessage() throws {
        let client = try AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
        let messages: [ChatMessage] = [
            .system("Be helpful"),
            .user("First question"),
            .assistant(AssistantMessage(content: "First answer")),
            .user("Second question"),
        ]
        let request = try client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let msgs = json["messages"] as? [[String: Any]]
        #expect(msgs?.count == 3)

        let firstUser = msgs?[0]["content"]
        #expect(firstUser is [[String: Any]])
        let blocks = firstUser as? [[String: Any]]
        #expect(blocks?.count == 1)
        #expect(blocks?[0]["text"] as? String == "First question")
        let cacheControl = blocks?[0]["cache_control"] as? [String: Any]
        #expect(cacheControl?["type"] as? String == "ephemeral")

        #expect(msgs?[2]["content"] as? String == "Second question")
    }

    @Test
    func conversationCachingSkippedWithOneUserMessage() throws {
        let client = try AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
        let request = try client.buildRequest(messages: [.user("Only one")], tools: [])
        let json = try encodeRequest(request)

        let msgs = json["messages"] as? [[String: Any]]
        #expect(msgs?.count == 1)
        #expect(msgs?[0]["content"] as? String == "Only one")
    }

    @Test
    func conversationCachingSkippedWhenDisabled() throws {
        let client = try AnthropicClient(apiKey: "k", model: "m", cachingEnabled: false)
        let messages: [ChatMessage] = [
            .user("First"),
            .assistant(AssistantMessage(content: "Reply")),
            .user("Second"),
        ]
        let request = try client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let msgs = json["messages"] as? [[String: Any]]
        #expect(msgs?[0]["content"] as? String == "First")
        #expect(msgs?[2]["content"] as? String == "Second")
    }

    @Test
    func conversationCachingWithMultipleExchanges() throws {
        let client = try AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
        let messages: [ChatMessage] = [
            .user("user1"),
            .assistant(AssistantMessage(content: "asst1")),
            .user("user2"),
            .assistant(AssistantMessage(content: "asst2")),
            .user("user3"),
        ]
        let request = try client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let msgs = json["messages"] as? [[String: Any]]
        #expect(msgs?.count == 5)

        #expect(msgs?[0]["content"] as? String == "user1")

        let user2Content = msgs?[2]["content"] as? [[String: Any]]
        #expect(user2Content?.count == 1)
        #expect(user2Content?[0]["text"] as? String == "user2")
        let cacheControl = user2Content?[0]["cache_control"] as? [String: Any]
        #expect(cacheControl?["type"] as? String == "ephemeral")

        #expect(msgs?[4]["content"] as? String == "user3")
    }

    @Test
    func conversationCachingIgnoresToolResultUserMessages() throws {
        let client = try AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
        let assistant = AssistantMessage(
            content: "Let me search",
            toolCalls: [ToolCall(id: "tc_1", name: "search", arguments: "{\"q\":\"test\"}")]
        )
        let messages: [ChatMessage] = [
            .user("Find info"),
            .assistant(assistant),
            .tool(id: "tc_1", name: "search", content: "Result data"),
            .user("Thanks"),
        ]
        let request = try client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let msgs = json["messages"] as? [[String: Any]]
        #expect(msgs?.count == 4)

        let firstContent = msgs?[0]["content"] as? [[String: Any]]
        #expect(firstContent?[0]["text"] as? String == "Find info")
        #expect(firstContent?[0]["cache_control"] != nil)

        let toolResultUser = msgs?[2]["content"] as? [[String: Any]]
        #expect(toolResultUser?[0]["type"] as? String == "tool_result")
        #expect(toolResultUser?[0]["cache_control"] == nil)

        #expect(msgs?[3]["content"] as? String == "Thanks")
    }
}
