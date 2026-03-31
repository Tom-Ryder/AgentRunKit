@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesRequestSerializationTests {
    private func makeClient(store: Bool = false) -> ResponsesAPIClient {
        ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            maxOutputTokens: 4096,
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: store
        )
    }

    private func makeClientWithReasoning(store: Bool = false) -> ResponsesAPIClient {
        ResponsesAPIClient(
            apiKey: "test-key",
            model: "o3",
            maxOutputTokens: 4096,
            baseURL: ResponsesAPIClient.openAIBaseURL,
            reasoningConfig: .medium,
            store: store
        )
    }

    @Test
    func userMessageMapsToInputItem() async throws {
        let client = makeClient()
        let request = try await client.buildRequest(messages: [.user("Hello")], tools: [])
        let json = try encodeRequest(request)

        let input = json["input"] as? [[String: Any]]
        #expect(input?.count == 1)
        #expect(input?[0]["type"] as? String == "message")
        #expect(input?[0]["role"] as? String == "user")
        #expect(input?[0]["content"] as? String == "Hello")
    }

    @Test
    func systemMessageExtractedToInstructions() async throws {
        let client = makeClient()
        let messages: [ChatMessage] = [.system("Be helpful"), .user("Hi")]
        let request = try await client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        #expect(json["instructions"] as? String == "Be helpful")
        let input = json["input"] as? [[String: Any]]
        #expect(input?.count == 1)
        #expect(input?[0]["role"] as? String == "user")
    }

    @Test
    func multipleSystemMessagesConcatenated() async throws {
        let client = makeClient()
        let messages: [ChatMessage] = [.system("First"), .system("Second"), .user("Hi")]
        let request = try await client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        #expect(json["instructions"] as? String == "First\nSecond")
    }

    @Test
    func assistantWithContentMapsToMessageItem() async throws {
        let client = makeClient()
        let messages: [ChatMessage] = [.assistant(AssistantMessage(content: "Response text"))]
        let request = try await client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let input = json["input"] as? [[String: Any]]
        #expect(input?.count == 1)
        #expect(input?[0]["type"] as? String == "message")
        #expect(input?[0]["role"] as? String == "assistant")
        let content = input?[0]["content"] as? [[String: Any]]
        #expect(content?[0]["type"] as? String == "output_text")
        #expect(content?[0]["text"] as? String == "Response text")
    }

    @Test
    func assistantWithToolCallsMapsFunctionCallItems() async throws {
        let client = makeClient()
        let toolCall = ToolCall(id: "call_123", name: "search", arguments: "{\"q\":\"test\"}")
        let msg = AssistantMessage(content: "", toolCalls: [toolCall])
        let request = try await client.buildRequest(messages: [.assistant(msg)], tools: [])
        let json = try encodeRequest(request)

        let input = json["input"] as? [[String: Any]]
        #expect(input?.count == 1)
        #expect(input?[0]["type"] as? String == "function_call")
        #expect(input?[0]["call_id"] as? String == "call_123")
        #expect(input?[0]["name"] as? String == "search")
        #expect(input?[0]["arguments"] as? String == "{\"q\":\"test\"}")
    }

    @Test
    func assistantWithReasoningDetailsEmitsReasoningItems() async throws {
        let client = makeClient()
        let details: [JSONValue] = [
            .object(["type": .string("reasoning"), "id": .string("rs_001")])
        ]
        let msg = AssistantMessage(content: "Answer", reasoningDetails: details)
        let request = try await client.buildRequest(messages: [.assistant(msg)], tools: [])
        let json = try encodeRequest(request)

        let input = json["input"] as? [[String: Any]]
        #expect(input?.count == 2)
        #expect(input?[0]["type"] as? String == "reasoning")
        #expect(input?[0]["id"] as? String == "rs_001")
        #expect(input?[1]["type"] as? String == "message")
    }

    @Test
    func toolResultMapsFunctionCallOutput() async throws {
        let client = makeClient()
        let messages: [ChatMessage] = [
            .tool(id: "call_123", name: "search", content: "{\"result\":\"found\"}")
        ]
        let request = try await client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        let input = json["input"] as? [[String: Any]]
        #expect(input?.count == 1)
        #expect(input?[0]["type"] as? String == "function_call_output")
        #expect(input?[0]["call_id"] as? String == "call_123")
        #expect(input?[0]["output"] as? String == "{\"result\":\"found\"}")
    }

    @Test
    func toolDefinitionsEncodeFlatNotNested() async throws {
        let client = makeClient()
        let tools = [
            ToolDefinition(
                name: "get_weather",
                description: "Get weather",
                parametersSchema: .object(properties: ["city": .string()], required: ["city"])
            )
        ]
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: tools)
        let json = try encodeRequest(request)

        let jsonTools = json["tools"] as? [[String: Any]]
        #expect(jsonTools?.count == 1)
        #expect(jsonTools?[0]["type"] as? String == "function")
        #expect(jsonTools?[0]["name"] as? String == "get_weather")
        #expect(jsonTools?[0]["description"] as? String == "Get weather")
        #expect(jsonTools?[0]["parameters"] != nil)
        #expect(jsonTools?[0]["function"] == nil)
    }

    @Test
    func includePopulatedWhenStoreFalse() async throws {
        let client = makeClient(store: false)
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["include"] as? [String] == ["reasoning.encrypted_content"])
    }

    @Test
    func includeAbsentWhenStoreTrue() async throws {
        let client = makeClient(store: true)
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["include"] == nil)
    }
}

struct ResponsesResponseParsingTests {
    private func makeClient() -> ResponsesAPIClient {
        ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
    }

    @Test
    func textResponseParsesCorrectly() async throws {
        let json = """
        {
            "id": "resp_001",
            "status": "completed",
            "output": [{
                "type": "message",
                "content": [{"type": "output_text", "text": "Hello there!"}]
            }],
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))
        let msg = await client.parseResponse(response)

        #expect(msg.content == "Hello there!")
        #expect(msg.toolCalls.isEmpty)
        #expect(msg.tokenUsage?.input == 100)
        #expect(msg.tokenUsage?.output == 50)
        #expect(msg.tokenUsage?.reasoning == 0)
    }

    @Test
    func functionCallParsesCorrectly() async throws {
        let json = """
        {
            "id": "resp_002",
            "status": "completed",
            "output": [{
                "type": "function_call",
                "call_id": "call_abc",
                "name": "get_weather",
                "arguments": "{\\"city\\": \\"NYC\\"}"
            }],
            "usage": {"input_tokens": 50, "output_tokens": 25}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))
        let msg = await client.parseResponse(response)

        #expect(msg.content == "")
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "call_abc")
        #expect(msg.toolCalls[0].name == "get_weather")
        #expect(msg.toolCalls[0].arguments == "{\"city\": \"NYC\"}")
    }

    @Test
    func reasoningOutputParsesCorrectly() async throws {
        let json = """
        {
            "id": "resp_003",
            "status": "completed",
            "output": [
                {"type": "reasoning", "id": "rs_001",
                 "summary": [{"type": "summary_text",
                              "text": "Thinking about it..."}]},
                {"type": "message",
                 "content": [{"type": "output_text",
                              "text": "The answer is 42."}]}
            ],
            "usage": {
                "input_tokens": 100,
                "output_tokens": 200,
                "output_tokens_details": {"reasoning_tokens": 150}
            }
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))
        let msg = await client.parseResponse(response)

        #expect(msg.content == "The answer is 42.")
        #expect(msg.reasoning?.content == "Thinking about it...")
        #expect(msg.reasoningDetails?.count == 1)
        #expect(msg.tokenUsage?.input == 100)
        #expect(msg.tokenUsage?.output == 50)
        #expect(msg.tokenUsage?.reasoning == 150)
    }

    @Test
    func multipleSummaryItemsConcatenated() async throws {
        let json = """
        {
            "id": "resp_005",
            "status": "completed",
            "output": [
                {"type": "reasoning", "id": "rs_001", "summary": [
                    {"type": "summary_text", "text": "First thought."},
                    {"type": "summary_text", "text": "Second thought."}
                ]},
                {"type": "message", "content": [{"type": "output_text", "text": "Done."}]}
            ],
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))
        let msg = await client.parseResponse(response)

        #expect(msg.reasoning?.content == "First thought.\nSecond thought.")
    }

    @Test
    func failedResponseDecodesErrorFields() async throws {
        let json = """
        {
            "id": "resp_006",
            "status": "failed",
            "output": [],
            "error": {"code": "server_error", "message": "Internal failure"}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))

        #expect(response.status == "failed")
        #expect(response.error?.code == "server_error")
        #expect(response.error?.message == "Internal failure")
    }

    @Test
    func responseWithErrorThrowsLLMError() async throws {
        let json = """
        {
            "id": "resp_007",
            "status": "failed",
            "output": [],
            "error": {"code": "server_error", "message": "Internal failure"}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))

        await #expect(throws: AgentError.self) {
            try await client.checkResponseError(response)
        }
    }

    @Test
    func usageMappingSubtractsReasoningTokens() async throws {
        let json = """
        {
            "id": "resp_004",
            "status": "completed",
            "output": [{"type": "message", "content": [{"type": "output_text", "text": "Hi"}]}],
            "usage": {"input_tokens": 80, "output_tokens": 120, "output_tokens_details": {"reasoning_tokens": 100}}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))
        let msg = await client.parseResponse(response)

        #expect(msg.tokenUsage == TokenUsage(input: 80, output: 20, reasoning: 100))
    }
}

struct ResponsesURLRequestTests {
    @Test
    func buildURLRequestSetsCorrectProperties() async throws {
        let client = ResponsesAPIClient(
            apiKey: "sk-test-123",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
    }

    @Test
    func buildURLRequestWithoutApiKeyOmitsAuth() async throws {
        let client = ResponsesAPIClient(
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func customResponsesPath() async throws {
        let client = try ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: #require(URL(string: "https://custom.api.com/v2")),
            responsesPath: "custom/responses"
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        let expected = "https://custom.api.com/v2/custom/responses"
        #expect(urlRequest.url?.absoluteString == expected)
    }
}

struct ResponsesStoreFieldTests {
    @Test
    func storeTrueIncludedInRequestBody() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL, store: true
        )
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["store"] as? Bool == true)
    }

    @Test
    func storeFalseIncludedInRequestBody() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL, store: false
        )
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["store"] as? Bool == false)
    }
}

struct ResponsesFormatMappingTests {
    @Test
    func responseFormatMapsToTextFormat() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL, store: false
        )
        let format = ResponseFormat.jsonSchema(TestResponsesOutput.self)
        let request = try await client.buildRequest(
            messages: [.user("Extract")], tools: [],
            responseFormat: format
        )
        let json = try encodeRequest(request)

        let text = json["text"] as? [String: Any]
        let fmt = text?["format"] as? [String: Any]
        #expect(fmt?["type"] as? String == "json_schema")
        #expect(fmt?["name"] as? String == "TestResponsesOutput")
        #expect(fmt?["strict"] as? Bool == true)
        #expect(fmt?["schema"] != nil)
    }
}

private struct TestResponsesOutput: SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: ["value": .string()], required: ["value"])
    }
}

struct ResponsesExtraFieldsTests {
    private func makeClient() -> ResponsesAPIClient {
        ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL, store: false
        )
    }

    @Test
    func validExtraFieldsEncodeIntoRequestBody() async throws {
        let request = try await makeClient().buildRequest(
            messages: [.user("Hi")], tools: [],
            extraFields: ["temperature": .double(0.7), "top_p": .double(0.9)]
        )
        let json = try encodeRequest(request)

        #expect(json["temperature"] as? Double == 0.7)
        #expect(json["top_p"] as? Double == 0.9)
    }

    @Test
    func invalidExtraFieldThrowsEncodingError() async throws {
        let request = try await makeClient().buildRequest(
            messages: [.user("Hi")], tools: [],
            extraFields: ["custom_field": .string("bad"), "temperature": .double(0.7)]
        )

        do {
            _ = try JSONEncoder().encode(request)
            Issue.record("Expected EncodingError")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(context.debugDescription.contains("custom_field"))
        } catch {
            Issue.record("Expected EncodingError.invalidValue, got \(error)")
        }
    }

    @Test
    func firstClassPropertyKeysRejectedAsExtraFields() async throws {
        let request = try await makeClient().buildRequest(
            messages: [.user("Hi")], tools: [],
            extraFields: ["model": .string("override")]
        )

        do {
            _ = try JSONEncoder().encode(request)
            Issue.record("Expected EncodingError")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(context.debugDescription.contains("model"))
        } catch {
            Issue.record("Expected EncodingError.invalidValue, got \(error)")
        }
    }

    @Test
    func emptyExtraFieldsEncodesNormally() async throws {
        let request = try await makeClient().buildRequest(
            messages: [.user("Hi")], tools: [],
            extraFields: [:]
        )
        let json = try encodeRequest(request)

        let expectedKeys: Set = ["model", "input", "store", "include"]
        let actualKeys = Set(json.keys)
        #expect(actualKeys == expectedKeys)
    }
}

struct ResponsesEdgeCaseTests {
    @Test
    func emptyToolsArrayOmitsToolsField() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL, store: false
        )
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["tools"] == nil)
    }

    @Test
    func emptyOutputArrayParsesToEmptyMessage() async throws {
        let json = """
        {
            "id": "resp_empty",
            "status": "completed",
            "output": [],
            "usage": {"input_tokens": 10, "output_tokens": 0}
        }
        """
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let response = try await client.decodeResponse(Data(json.utf8))
        let msg = await client.parseResponse(response)

        #expect(msg.content == "")
        #expect(msg.toolCalls.isEmpty)
        #expect(msg.tokenUsage?.input == 10)
        #expect(msg.tokenUsage?.output == 0)
    }

    @Test
    func usageWithoutReasoningTokensDefaultsToZero() async throws {
        let json = """
        {
            "id": "resp_no_reasoning",
            "status": "completed",
            "output": [{"type": "message", "content": [{"type": "output_text", "text": "Hi"}]}],
            "usage": {"input_tokens": 50, "output_tokens": 20, "output_tokens_details": {}}
        }
        """
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let response = try await client.decodeResponse(Data(json.utf8))
        let msg = await client.parseResponse(response)

        #expect(msg.tokenUsage == TokenUsage(input: 50, output: 20, reasoning: 0))
    }

    @Test
    func multimodalWithNonTextPartThrows() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let messages: [ChatMessage] = [
            .userMultimodal([.text("Look at this"), .imageURL("https://example.com/img.png")])
        ]

        await #expect(throws: AgentError.self) {
            _ = try await client.buildRequest(messages: messages, tools: [])
        }
    }

    @Test
    func multimodalWithOnlyTextPartsSucceeds() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let messages: [ChatMessage] = [
            .userMultimodal([.text("Part one"), .text("Part two")])
        ]

        let request = try await client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)
        let input = json["input"] as? [[String: Any]]
        #expect(input?[0]["content"] as? String == "Part one\nPart two")
    }
}
