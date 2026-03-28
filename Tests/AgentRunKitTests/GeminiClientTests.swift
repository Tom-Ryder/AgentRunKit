@testable import AgentRunKit
import Foundation
import Testing

private func encodeRequest(_ request: GeminiRequest) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
    guard let dict = object as? [String: Any] else {
        preconditionFailure("Encoded request is not a JSON object: \(object)")
    }
    return dict
}

// MARK: - Request Serialization Tests

struct GeminiRequestSerializationTests {
    private func makeClient(
        reasoningConfig: ReasoningConfig? = nil,
        maxOutputTokens: Int = 8192
    ) -> GeminiClient {
        GeminiClient(
            apiKey: "test-key", model: "gemini-2.5-pro",
            maxOutputTokens: maxOutputTokens,
            reasoningConfig: reasoningConfig
        )
    }

    @Test
    func userMessageMapsCorrectly() throws {
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hello")], tools: [])
        let json = try encodeRequest(request)

        let contents = json["contents"] as? [[String: Any]]
        #expect(contents?.count == 1)
        #expect(contents?[0]["role"] as? String == "user")
        let parts = contents?[0]["parts"] as? [[String: Any]]
        #expect(parts?.count == 1)
        #expect(parts?[0]["text"] as? String == "Hello")
    }

    @Test
    func systemMessageExtractedToSystemInstruction() throws {
        let client = makeClient()
        let messages: [ChatMessage] = [.system("Be helpful"), .user("Hi")]
        let request = try client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let system = json["systemInstruction"] as? [String: Any]
        let sysParts = system?["parts"] as? [[String: Any]]
        #expect(sysParts?.count == 1)
        #expect(sysParts?[0]["text"] as? String == "Be helpful")

        let contents = json["contents"] as? [[String: Any]]
        #expect(contents?.count == 1)
        #expect(contents?[0]["role"] as? String == "user")
    }

    @Test
    func multipleSystemMessagesMerged() throws {
        let client = makeClient()
        let messages: [ChatMessage] = [.system("First"), .system("Second"), .user("Hi")]
        let request = try client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let system = json["systemInstruction"] as? [String: Any]
        let sysParts = system?["parts"] as? [[String: Any]]
        #expect(sysParts?.count == 2)
        #expect(sysParts?[0]["text"] as? String == "First")
        #expect(sysParts?[1]["text"] as? String == "Second")
    }

    @Test
    func noSystemOmitsField() throws {
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["systemInstruction"] == nil)
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
        let decls = jsonTools?[0]["functionDeclarations"] as? [[String: Any]]
        #expect(decls?.count == 1)
        #expect(decls?[0]["name"] as? String == "get_weather")
        #expect(decls?[0]["description"] as? String == "Get weather")
        let schema = decls?[0]["parameters"] as? [String: Any]
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
        #expect(json["toolConfig"] == nil)
    }

    @Test
    func maxOutputTokensEncodes() throws {
        let client = makeClient(maxOutputTokens: 4096)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generationConfig"] as? [String: Any]
        #expect(genConfig?["maxOutputTokens"] as? Int == 4096)
    }

    @Test
    func thinkingConfigEncodes() throws {
        let client = makeClient(reasoningConfig: .high)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generationConfig"] as? [String: Any]
        let thinking = genConfig?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["includeThoughts"] as? Bool == true)
        #expect(thinking?["thinkingLevel"] as? String == "HIGH")
        #expect(thinking?["thinkingBudget"] == nil)
    }

    @Test
    func noReasoningOmitsThinkingConfig() throws {
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generationConfig"] as? [String: Any]
        #expect(genConfig?["thinkingConfig"] == nil)
    }

    @Test
    func noneEffortOmitsThinkingConfig() throws {
        let client = makeClient(reasoningConfig: ReasoningConfig.none)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generationConfig"] as? [String: Any]
        #expect(genConfig?["thinkingConfig"] == nil)
    }

    @Test
    func explicitBudgetTokensEncodes() throws {
        let client = makeClient(reasoningConfig: .budget(10000))
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generationConfig"] as? [String: Any]
        let thinking = genConfig?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["includeThoughts"] as? Bool == true)
        #expect(thinking?["thinkingBudget"] as? Int == 10000)
        #expect(thinking?["thinkingLevel"] == nil)
    }

    @Test
    func effortWithBudgetSendsOnlyBudget() throws {
        // Simulates what ProviderService produces: effort + budgetTokens.
        let config = ReasoningConfig(effort: .medium, budgetTokens: 32000)
        let client = makeClient(reasoningConfig: config)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generationConfig"] as? [String: Any]
        let thinking = genConfig?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["includeThoughts"] as? Bool == true)
        #expect(thinking?["thinkingBudget"] as? Int == 32000)
        #expect(thinking?["thinkingLevel"] == nil)
    }

    @Test
    func effortMappingValues() {
        let efforts: [(ReasoningConfig.Effort, String)] = [
            (.xhigh, "HIGH"), (.high, "HIGH"), (.medium, "MEDIUM"),
            (.low, "LOW"), (.minimal, "MINIMAL")
        ]
        for (effort, expectedLevel) in efforts {
            let client = GeminiClient(
                apiKey: "k", model: "m",
                reasoningConfig: ReasoningConfig(effort: effort)
            )
            let config = client.buildThinkingConfig()
            #expect(config?.thinkingLevel == expectedLevel)
            #expect(config?.includeThoughts == true)
        }
    }

    @Test
    func validExtraFieldsEncode() throws {
        let client = makeClient()
        let request = try client.buildRequest(
            messages: [.user("Hi")], tools: [],
            extraFields: ["temperature": .double(0.7), "topP": .double(0.9)]
        )
        let json = try encodeRequest(request)

        #expect(json["temperature"] as? Double == 0.7)
        #expect(json["topP"] as? Double == 0.9)
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
    func toolConfigEncodesAutoMode() throws {
        let client = makeClient()
        let tools = [
            ToolDefinition(
                name: "search", description: "Search",
                parametersSchema: .object(properties: ["q": .string()], required: ["q"])
            )
        ]
        let request = try client.buildRequest(messages: [.user("Hi")], tools: tools)
        let json = try encodeRequest(request)

        let toolConfig = json["toolConfig"] as? [String: Any]
        let funcConfig = toolConfig?["functionCallingConfig"] as? [String: Any]
        #expect(funcConfig?["mode"] as? String == "AUTO")
    }
}

// MARK: - URL Request Tests

struct GeminiURLRequestTests {
    @Test
    func setsCorrectURL() throws {
        let client = GeminiClient(
            apiKey: "test-api-key-123",
            model: "gemini-2.5-pro"
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request, stream: false)

        let url = try #require(urlRequest.url)
        #expect(url.path.contains("models/gemini-2.5-pro:generateContent"))
        #expect(url.query?.contains("key=test-api-key-123") == true)
        #expect(url.query?.contains("alt=sse") != true)
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func streamURLHasAltSSE() throws {
        let client = GeminiClient(
            apiKey: "test-key",
            model: "gemini-2.5-pro"
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request, stream: true)

        let url = try #require(urlRequest.url)
        #expect(url.path.contains("models/gemini-2.5-pro:streamGenerateContent"))
        #expect(url.query?.contains("alt=sse") == true)
        #expect(url.query?.contains("key=test-key") == true)
    }

    @Test
    func customBaseURL() throws {
        let client = try GeminiClient(
            apiKey: "test-key",
            model: "gemini-2.5-flash",
            baseURL: #require(URL(string: "https://custom.api.example.com"))
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request, stream: false)

        #expect(urlRequest.url?.host == "custom.api.example.com")
    }

    @Test
    func additionalHeadersApplied() throws {
        let client = GeminiClient(
            apiKey: "test-key",
            model: "gemini-2.5-pro",
            additionalHeaders: { ["X-Custom": "value123"] }
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request, stream: false)

        #expect(urlRequest.value(forHTTPHeaderField: "X-Custom") == "value123")
    }

    @Test
    func defaultModelUsedWhenNil() throws {
        let client = GeminiClient(apiKey: "test-key")
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request, stream: false)

        #expect(urlRequest.url?.path.contains("models/gemini-2.5-flash") == true)
    }

    @Test
    func customApiVersion() throws {
        let client = GeminiClient(
            apiKey: "test-key",
            model: "gemini-2.5-pro",
            apiVersion: "v1"
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request, stream: false)

        #expect(urlRequest.url?.path.contains("/v1/") == true)
    }
}

// MARK: - Message Mapper Tests

struct GeminiMessageMapperTests {
    @Test
    func toolResultsMergedIntoSingleContent() throws {
        let messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "{\"result\": \"found\"}"),
            .tool(id: "call_2", name: "lookup", content: "{\"data\": \"value\"}")
        ]
        let (_, mapped) = try GeminiMessageMapper.mapMessages(messages)

        #expect(mapped.count == 1)
        #expect(mapped[0].role == "user")
        #expect(mapped[0].parts.count == 2)
        #expect(mapped[0].parts[0].functionResponse?.name == "search")
        #expect(mapped[0].parts[0].functionResponse?.id == "call_1")
        #expect(mapped[0].parts[1].functionResponse?.name == "lookup")
        #expect(mapped[0].parts[1].functionResponse?.id == "call_2")
    }

    @Test
    func toolResultWithPlainTextWrappedInObject() throws {
        let messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "plain text result")
        ]
        let (_, mapped) = try GeminiMessageMapper.mapMessages(messages)

        #expect(mapped.count == 1)
        let response = mapped[0].parts[0].functionResponse
        #expect(response?.name == "search")
        guard case let .object(dict) = response?.response else {
            Issue.record("Expected object response")
            return
        }
        #expect(dict["result"] == .string("plain text result"))
    }

    @Test
    func assistantWithReasoningDetailsRoundTrips() throws {
        let details: [JSONValue] = [
            .object([
                "type": .string("thinking"),
                "thinking": .string("reasoning text"),
                "signature": .string("sig_abc")
            ])
        ]
        let msg = AssistantMessage(content: "Answer", reasoningDetails: details)
        let (_, mapped) = try GeminiMessageMapper.mapMessages([.assistant(msg)])

        #expect(mapped.count == 1)
        #expect(mapped[0].role == "model")
        #expect(mapped[0].parts.count == 2)
        #expect(mapped[0].parts[0].text == "reasoning text")
        #expect(mapped[0].parts[0].thought == true)
        #expect(mapped[0].parts[0].thoughtSignature == "sig_abc")
        #expect(mapped[0].parts[1].text == "Answer")
        #expect(mapped[0].parts[1].thought == nil)
    }

    @Test
    func assistantFallbackToReasoningContent() throws {
        let reasoning = ReasoningContent(content: "thinking", signature: "sig_xyz")
        let msg = AssistantMessage(content: "Answer", reasoning: reasoning)
        let (_, mapped) = try GeminiMessageMapper.mapMessages([.assistant(msg)])

        #expect(mapped[0].role == "model")
        #expect(mapped[0].parts.count == 2)
        #expect(mapped[0].parts[0].text == "thinking")
        #expect(mapped[0].parts[0].thought == true)
        #expect(mapped[0].parts[0].thoughtSignature == "sig_xyz")
        #expect(mapped[0].parts[1].text == "Answer")
    }

    @Test
    func reasoningWithoutSignature() throws {
        let reasoning = ReasoningContent(content: "thinking")
        let msg = AssistantMessage(content: "Answer", reasoning: reasoning)
        let (_, mapped) = try GeminiMessageMapper.mapMessages([.assistant(msg)])

        #expect(mapped[0].parts.count == 2)
        #expect(mapped[0].parts[0].thought == true)
        #expect(mapped[0].parts[0].thoughtSignature == nil)
    }

    @Test
    func multimodalThrows() {
        do {
            _ = try GeminiMessageMapper.mapMessages([
                .userMultimodal([.text("Hi"), .imageURL("https://example.com/img.png")])
            ])
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .other(msg) = transport
            else {
                Issue.record("Expected .other, got \(error)")
                return
            }
            #expect(msg.contains("multimodal"))
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
    }

    @Test
    func mixedConversation() throws {
        let toolCall = ToolCall(id: "call_1", name: "search", arguments: "{\"q\":\"test\"}")
        let messages: [ChatMessage] = [
            .system("Be helpful"),
            .user("Search for test"),
            .assistant(AssistantMessage(content: "", toolCalls: [toolCall])),
            .tool(id: "call_1", name: "search", content: "{\"found\": true}")
        ]
        let (system, mapped) = try GeminiMessageMapper.mapMessages(messages)

        #expect(system != nil)
        #expect(system?.parts.count == 1)
        #expect(mapped.count == 3)
        #expect(mapped[0].role == "user")
        #expect(mapped[1].role == "model")
        #expect(mapped[2].role == "user")
        #expect(mapped[2].parts[0].functionResponse != nil)
    }

    @Test
    func emptyAssistantGetsEmptyTextPart() throws {
        let msg = AssistantMessage(content: "")
        let (_, mapped) = try GeminiMessageMapper.mapMessages([.assistant(msg)])

        #expect(mapped[0].parts.count == 1)
        #expect(mapped[0].parts[0].text == "")
    }
}

// MARK: - Response Format Tests

struct GeminiResponseFormatTests {
    @Test
    func responseFormatEncodesInGenerationConfig() throws {
        let client = GeminiClient(apiKey: "k", model: "m")
        let format = ResponseFormat.jsonSchema(TestGeminiOutput.self)
        let request = try client.buildRequest(
            messages: [.user("Hi")], tools: [], responseFormat: format
        )
        let json = try encodeRequest(request)

        let genConfig = json["generationConfig"] as? [String: Any]
        #expect(genConfig?["responseMimeType"] as? String == "application/json")
        #expect(genConfig?["responseSchema"] != nil)
    }

    @Test
    func noResponseFormatOmitsFields() throws {
        let client = GeminiClient(apiKey: "k", model: "m")
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generationConfig"] as? [String: Any]
        #expect(genConfig?["responseMimeType"] == nil)
        #expect(genConfig?["responseSchema"] == nil)
    }
}

private enum TestGeminiOutput: SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: ["value": .string()], required: ["value"])
    }
}

// MARK: - GeminiSchema Tests

struct GeminiSchemaTests {
    private func assertNoAdditionalProperties(
        _ value: Any, path: String = "$"
    ) {
        if let dict = value as? [String: Any] {
            if dict["additionalProperties"] != nil {
                Issue.record("Found additionalProperties at \(path)")
            }
            for (key, child) in dict {
                assertNoAdditionalProperties(child, path: "\(path).\(key)")
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                assertNoAdditionalProperties(child, path: "\(path)[\(index)]")
            }
        }
    }

    @Test
    func stripsAdditionalPropertiesRecursively() throws {
        let schema = GeminiSchema(
            .object(
                properties: [
                    "name": .string(description: "User name"),
                    "age": .integer(description: "Age"),
                    "score": .number(),
                    "active": .boolean(),
                    "role": .string(enumValues: ["admin", "user"]),
                    "address": .object(
                        properties: ["city": .string(), "zip": .string()],
                        required: ["city"]
                    ),
                    "items": .array(items:
                        .object(
                            properties: [
                                "meta": .object(
                                    properties: ["key": .string()],
                                    required: ["key"]
                                )
                            ],
                            required: ["meta"]
                        )),
                    "optional_field": .anyOf([
                        .object(properties: ["a": .string()], required: ["a"]),
                        .null
                    ])
                ],
                required: ["name"],
                description: "User record"
            )
        )
        let data = try JSONEncoder().encode(schema)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        assertNoAdditionalProperties(json)

        #expect(json["type"] as? String == "object")
        #expect(json["description"] as? String == "User record")
        #expect(json["required"] as? [String] == ["name"])

        let props = json["properties"] as? [String: Any]
        #expect((props?["name"] as? [String: Any])?["type"] as? String == "string")
        #expect((props?["age"] as? [String: Any])?["type"] as? String == "integer")
        #expect((props?["score"] as? [String: Any])?["type"] as? String == "number")
        #expect((props?["active"] as? [String: Any])?["type"] as? String == "boolean")
        #expect((props?["role"] as? [String: Any])?["enum"] as? [String] == ["admin", "user"])

        let address = props?["address"] as? [String: Any]
        #expect(address?["type"] as? String == "object")
    }

    @Test
    func geminiRequestToolSchemaOmitsAdditionalProperties() throws {
        let client = GeminiClient(apiKey: "test-key", model: "gemini-2.5-pro")
        let tools = [
            ToolDefinition(
                name: "create_user",
                description: "Create a user",
                parametersSchema: .object(
                    properties: [
                        "name": .string(),
                        "address": .object(
                            properties: ["street": .string(), "city": .string()],
                            required: ["street", "city"]
                        ),
                        "tags": .array(items: .string())
                    ],
                    required: ["name", "address"]
                )
            )
        ]
        let request = try client.buildRequest(messages: [.user("Hi")], tools: tools)
        let json = try encodeRequest(request)

        let jsonTools = json["tools"] as? [[String: Any]]
        let decls = jsonTools?[0]["functionDeclarations"] as? [[String: Any]]
        let params = try #require(decls?[0]["parameters"] as? [String: Any])

        assertNoAdditionalProperties(params)
        #expect(params["type"] as? String == "object")
    }

    @Test
    func responseFormatSchemaOmitsAdditionalProperties() throws {
        let client = GeminiClient(apiKey: "k", model: "m")
        let format = ResponseFormat.jsonSchema(TestGeminiOutput.self)
        let request = try client.buildRequest(
            messages: [.user("Hi")], tools: [], responseFormat: format
        )
        let json = try encodeRequest(request)

        let genConfig = try #require(json["generationConfig"] as? [String: Any])
        let responseSchema = try #require(genConfig["responseSchema"] as? [String: Any])
        assertNoAdditionalProperties(responseSchema)
        #expect(responseSchema["type"] as? String == "object")
    }
}
