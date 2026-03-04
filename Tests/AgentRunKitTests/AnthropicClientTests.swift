import Foundation
import Testing

@testable import AgentRunKit

private func encodeRequest(_ request: AnthropicRequest) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
    guard let dict = object as? [String: Any] else {
        preconditionFailure("Encoded request is not a JSON object: \(object)")
    }
    return dict
}

@Suite
struct AnthropicRequestSerializationTests {
    private func makeClient(
        reasoningConfig: ReasoningConfig? = nil, interleavedThinking: Bool = false, maxTokens: Int = 8192
    ) -> AnthropicClient {
        AnthropicClient(
            apiKey: "test-key", model: "claude-sonnet-4-6", maxTokens: maxTokens,
            reasoningConfig: reasoningConfig, interleavedThinking: interleavedThinking
        )
    }

    @Test
    func userMessageMapsCorrectly() throws {
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hello")], tools: [])
        let json = try encodeRequest(request)

        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?[0]["role"] as? String == "user")
        #expect(messages?[0]["content"] as? String == "Hello")
    }

    @Test
    func systemMessageExtractedToTopLevel() throws {
        let client = makeClient()
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
        let client = makeClient()
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
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["system"] == nil)
    }

    @Test
    func toolDefinitionsEncode() throws {
        let client = makeClient()
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
    func emptyToolsOmitsField() throws {
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["tools"] == nil)
    }

    @Test
    func maxTokensEncodes() throws {
        let client = makeClient(maxTokens: 4096)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["max_tokens"] as? Int == 4096)
    }

    @Test
    func streamFlagEncodes() throws {
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [], stream: true)
        let json = try encodeRequest(request)

        #expect(json["stream"] as? Bool == true)
    }

    @Test
    func streamFlagOmittedWhenFalse() throws {
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["stream"] == nil)
    }

    @Test
    func thinkingConfigEncodes() throws {
        let client = makeClient(reasoningConfig: .high, maxTokens: 65536)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let thinking = json["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["budget_tokens"] as? Int == 16384)
    }

    @Test
    func thinkingDisabledForNoneEffort() throws {
        let client = makeClient(reasoningConfig: ReasoningConfig.none)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let thinking = json["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "disabled")
    }

    @Test
    func noReasoningOmitsThinking() throws {
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["thinking"] == nil)
    }

    @Test
    func validExtraFieldsEncode() throws {
        let client = makeClient()
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
        let client = makeClient()
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
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["model"] as? String == "claude-sonnet-4-6")
    }
}

@Suite
struct AnthropicURLRequestTests {
    @Test
    func setsCorrectHeaders() throws {
        let client = AnthropicClient(
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
        let client = AnthropicClient(
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
    func noBetaHeaderWithoutInterleavedThinking() throws {
        let client = AnthropicClient(
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
        let client = AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            interleavedThinking: true
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test
    func responseFormatThrows() async {
        let client = AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6"
        )
        let format = ResponseFormat.jsonSchema(TestAnthropicOutput.self)
        await #expect(throws: AgentError.self) {
            _ = try await client.generate(
                messages: [.user("Hi")],
                tools: [],
                responseFormat: format
            )
        }
    }

    @Test
    func customBaseURL() throws {
        let client = AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            baseURL: URL(string: "https://custom.api.example.com/v2")!
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://custom.api.example.com/v2/messages")
    }

    @Test
    func additionalHeadersApplied() throws {
        let client = AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            additionalHeaders: { ["X-Custom": "value123", "x-api-key": "fake"] }
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "X-Custom") == "value123")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "test-key")
    }
}

@Suite
struct AnthropicBudgetMappingTests {
    @Test
    func effortMappingValues() throws {
        let efforts: [(ReasoningConfig.Effort, Int)] = [
            (.xhigh, 32768), (.high, 16384), (.medium, 8192),
            (.low, 4096), (.minimal, 1024)
        ]
        for (effort, expected) in efforts {
            let client = AnthropicClient(
                apiKey: "k", maxTokens: 65536,
                reasoningConfig: ReasoningConfig(effort: effort)
            )
            let config = try client.buildThinkingConfig()
            guard case let .some(thinking) = config else {
                Issue.record("Expected thinking config for \(effort)")
                continue
            }
            #expect(thinking.budgetTokens == expected)
        }
    }

    @Test
    func budgetFlooredTo1024() throws {
        let client = AnthropicClient(
            apiKey: "k", maxTokens: 65536,
            reasoningConfig: .budget(500)
        )
        let config = try client.buildThinkingConfig()
        #expect(config?.budgetTokens == 1024)
    }

    @Test
    func budgetCappedToMaxTokensMinusOne() throws {
        let client = AnthropicClient(
            apiKey: "k", maxTokens: 2048,
            reasoningConfig: .budget(4096),
            interleavedThinking: false
        )
        let config = try client.buildThinkingConfig()
        #expect(config?.budgetTokens == 2047)
    }

    @Test
    func interleavedSkipsCap() throws {
        let client = AnthropicClient(
            apiKey: "k", maxTokens: 2048,
            reasoningConfig: .budget(4096)
        )
        let config = try client.buildThinkingConfig()
        #expect(config?.budgetTokens == 4096)
    }

    @Test
    func budgetBelowFloorAfterCapThrows() {
        let client = AnthropicClient(
            apiKey: "k", maxTokens: 1024,
            reasoningConfig: .budget(2048),
            interleavedThinking: false
        )
        #expect(throws: AgentError.self) {
            _ = try client.buildThinkingConfig()
        }
    }

    @Test
    func explicitBudgetTokensUsed() throws {
        let client = AnthropicClient(
            apiKey: "k", maxTokens: 65536,
            reasoningConfig: .budget(10000)
        )
        let config = try client.buildThinkingConfig()
        #expect(config?.budgetTokens == 10000)
    }

    @Test
    func noneEffortWithExplicitBudgetUsesBudget() throws {
        let client = AnthropicClient(
            apiKey: "k", maxTokens: 65536,
            reasoningConfig: ReasoningConfig(effort: .none, budgetTokens: 4096)
        )
        let config = try client.buildThinkingConfig()
        #expect(config?.budgetTokens == 4096)
    }
}

@Suite
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
        let client = AnthropicClient(apiKey: "k", model: "m", cachingEnabled: false)
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
        let client = AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
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
        let client = AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
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
        let client = AnthropicClient(apiKey: "k", model: "m", cachingEnabled: true)
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: []
        )
        let json = try encodeRequest(request)
        #expect(json["system"] == nil)
        #expect(json["tools"] == nil)
    }
}

private enum TestAnthropicOutput: SchemaProviding {
    static var jsonSchema: JSONSchema { .object(properties: ["value": .string()], required: ["value"]) }
}
