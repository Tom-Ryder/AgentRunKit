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
    func assistantWithResponsesContinuityReplaysRawOutputItems() async throws {
        let json = """
        {
            "id": "resp_010",
            "status": "completed",
            "output": [
                {
                    "type": "reasoning",
                    "id": "rs_001",
                    "status": "completed",
                    "summary": [{"type": "summary_text", "text": "Thinking"}]
                },
                {
                    "type": "message",
                    "id": "msg_001",
                    "status": "completed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": "Answer"}]
                },
                {
                    "type": "function_call",
                    "id": "fc_001",
                    "status": "completed",
                    "call_id": "call_123",
                    "name": "search",
                    "arguments": "{\\"q\\":\\"test\\"}"
                }
            ],
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))
        let message = await client.parseResponse(response)
        let request = try await client.buildRequest(messages: [.assistant(message)], tools: [])
        let encoded = try encodeRequest(request)

        let input = encoded["input"] as? [[String: Any]]
        #expect(input?.count == 3)
        #expect(input?[0]["type"] as? String == "reasoning")
        #expect(input?[0]["id"] as? String == "rs_001")
        #expect(input?[0]["status"] as? String == "completed")
        let reasoningSummary = input?[0]["summary"] as? [[String: Any]]
        #expect(reasoningSummary?.count == 1)
        #expect(reasoningSummary?[0]["type"] as? String == "summary_text")
        #expect(reasoningSummary?[0]["text"] as? String == "Thinking")
        #expect(input?[1]["type"] as? String == "message")
        #expect(input?[1]["id"] as? String == "msg_001")
        #expect(input?[1]["status"] as? String == "completed")
        let messageContent = input?[1]["content"] as? [[String: Any]]
        #expect(messageContent?.count == 1)
        #expect(messageContent?[0]["type"] as? String == "output_text")
        #expect(messageContent?[0]["text"] as? String == "Answer")
        #expect(input?[2]["type"] as? String == "function_call")
        #expect(input?[2]["id"] as? String == "fc_001")
        #expect(input?[2]["status"] as? String == "completed")
        #expect(input?[2]["call_id"] as? String == "call_123")
        #expect(input?[2]["name"] as? String == "search")
        #expect(input?[2]["arguments"] as? String == "{\"q\":\"test\"}")
    }

    @Test
    func foreignContinuityFallsBackToSemanticReplay() async throws {
        let client = makeClient()
        let toolCall = ToolCall(id: "call_123", name: "search", arguments: "{\"q\":\"test\"}")
        let message = AssistantMessage(
            content: "Answer",
            toolCalls: [toolCall],
            continuity: AssistantContinuity(
                substrate: .openAIChatCompletions,
                payload: .object(["id": .string("ignored")])
            )
        )
        let request = try await client.buildRequest(messages: [.assistant(message)], tools: [])
        let encoded = try encodeRequest(request)

        let input = encoded["input"] as? [[String: Any]]
        #expect(input?.count == 2)
        #expect(input?[0]["type"] as? String == "message")
        #expect(input?[1]["type"] as? String == "function_call")
        #expect(input?[1]["call_id"] as? String == "call_123")
    }

    @Test
    func malformedResponsesContinuityMissingOutputThrows() async throws {
        let client = makeClient()
        let message = AssistantMessage(
            content: "",
            continuity: AssistantContinuity(substrate: .responses, payload: .object([:]))
        )

        await #expect(throws: AgentError.self) {
            _ = try await client.buildRequest(messages: [.assistant(message)], tools: [])
        }
    }

    @Test
    func malformedResponsesContinuityEmptyOutputThrows() async throws {
        let client = makeClient()
        let message = AssistantMessage(
            content: "",
            continuity: AssistantContinuity(
                substrate: .responses,
                payload: .object(["output": .array([])])
            )
        )

        await #expect(throws: AgentError.self) {
            _ = try await client.buildRequest(messages: [.assistant(message)], tools: [])
        }
    }

    @Test
    func malformedResponsesContinuityMalformedFunctionCallThrows() async throws {
        let client = makeClient()
        let message = AssistantMessage(
            content: "",
            continuity: AssistantContinuity(
                substrate: .responses,
                payload: .object([
                    "output": .array([
                        .object([
                            "type": .string("function_call"),
                            "call_id": .string("call_123"),
                            "arguments": .string("{}"),
                        ])
                    ])
                ])
            )
        )

        await #expect(throws: AgentError.self) {
            _ = try await client.buildRequest(messages: [.assistant(message)], tools: [])
        }
    }

    @Test
    func malformedResponsesContinuityNonAssistantMessageRoleThrows() async throws {
        let client = makeClient()
        let message = AssistantMessage(
            content: "",
            continuity: AssistantContinuity(
                substrate: .responses,
                payload: .object([
                    "output": .array([
                        .object([
                            "type": .string("message"),
                            "role": .string("user"),
                            "content": .array([
                                .object([
                                    "type": .string("output_text"),
                                    "text": .string("Hello"),
                                ])
                            ]),
                        ])
                    ])
                ])
            )
        )

        await #expect(throws: AgentError.self) {
            _ = try await client.buildRequest(messages: [.assistant(message)], tools: [])
        }
    }

    @Test
    func unsupportedContinuityItemPreservedAsOpaqueAcrossReplay() async throws {
        let client = makeClient()
        let message = AssistantMessage(
            content: "",
            continuity: AssistantContinuity(
                substrate: .responses,
                payload: .object([
                    "output": .array([
                        .object([
                            "type": .string("image"),
                            "url": .string("https://example.com/image.png"),
                        ])
                    ])
                ])
            )
        )

        let request = try await client.buildRequest(messages: [.assistant(message)], tools: [])
        let encoded = try encodeRequest(request)
        let input = try #require(encoded["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "image")
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
    func hostedToolsEncodeAlongsideFunctionTools() async throws {
        let client = makeClient()
        let tools = [
            ToolDefinition(
                name: "get_weather",
                description: "Get weather",
                parametersSchema: .object(properties: ["city": .string()], required: ["city"])
            )
        ]
        let request = try await client.buildRequest(
            messages: [.user("Hi")],
            tools: tools,
            options: ResponsesRequestOptions(hostedTools: [
                .fileSearch(vectorStoreIDs: ["vs_123"], maxNumResults: 5),
                .webSearch(
                    externalWebAccess: false,
                    userLocation: ResponsesApproximateUserLocation(country: "US", city: "SF")
                ),
            ])
        )
        let json = try encodeRequest(request)

        let jsonTools = try #require(json["tools"] as? [[String: Any]])
        #expect(jsonTools.count == 3)
        #expect(jsonTools[0]["type"] as? String == "function")
        #expect(jsonTools[1]["type"] as? String == "file_search")
        #expect(jsonTools[1]["vector_store_ids"] as? [String] == ["vs_123"])
        #expect(jsonTools[1]["max_num_results"] as? Int == 5)
        #expect(jsonTools[2]["type"] as? String == "web_search")
        #expect(jsonTools[2]["external_web_access"] as? Bool == false)
        let location = try #require(jsonTools[2]["user_location"] as? [String: Any])
        #expect(location["type"] as? String == "approximate")
        #expect(location["country"] as? String == "US")
        #expect(location["city"] as? String == "SF")
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
        #expect(msg.continuity?.substrate == .responses)
        #expect(msg.tokenUsage?.input == 100)
        #expect(msg.tokenUsage?.output == 50)
        #expect(msg.tokenUsage?.reasoning == 150)
    }

    @Test
    func responsePersistsResponsesContinuityPayload() async throws {
        let json = """
        {
            "id": "resp_continuity",
            "status": "completed",
            "output": [
                {
                    "type": "message",
                    "id": "msg_001",
                    "status": "completed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": "Hello there!"}]
                }
            ],
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))
        let message = await client.parseResponse(response)

        #expect(message.continuity?.substrate == .responses)
        guard case let .object(payload) = message.continuity?.payload else {
            Issue.record("Expected Responses continuity payload")
            return
        }
        #expect(payload["response_id"] == .string("resp_continuity"))
        #expect(payload["response_status"] == nil)
        guard case let .array(output) = payload["output"] else {
            Issue.record("Expected output array in continuity payload")
            return
        }
        #expect(output.count == 1)
        guard case let .object(first) = output[0] else {
            Issue.record("Expected first replay item to be an object")
            return
        }
        #expect(first["type"] == .string("message"))
        #expect(first["id"] == .string("msg_001"))
        #expect(first["status"] == .string("completed"))
    }

    @Test
    func missingOutputFieldThrowsDecodingError() async throws {
        let json = """
        {
            "id": "resp_missing_output",
            "status": "completed",
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let client = makeClient()

        await #expect(throws: AgentError.self) {
            _ = try await client.decodeResponse(Data(json.utf8))
        }
    }

    @Test
    func nullOutputFieldThrowsDecodingError() async throws {
        let json = """
        {
            "id": "resp_null_output",
            "status": "completed",
            "output": null,
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let client = makeClient()

        await #expect(throws: AgentError.self) {
            _ = try await client.decodeResponse(Data(json.utf8))
        }
    }

    @Test
    func unsupportedOutputItemPreservedAsOpaqueInContinuity() async throws {
        let json = """
        {
            "id": "resp_unknown_output",
            "status": "completed",
            "output": [
                {
                    "type": "image",
                    "url": "https://example.com/image.png"
                },
                {
                    "type": "message",
                    "content": [{"type": "output_text", "text": "Hello"}]
                }
            ],
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))
        let message = await client.parseResponse(response)
        let request = try await client.buildRequest(messages: [.assistant(message)], tools: [])
        let encoded = try encodeRequest(request)

        #expect(message.content == "Hello")
        #expect(message.reasoningDetails == nil)
        guard case let .object(payload) = message.continuity?.payload else {
            Issue.record("Expected Responses continuity payload")
            return
        }
        guard case let .array(output) = payload["output"] else {
            Issue.record("Expected output array in continuity payload")
            return
        }
        #expect(output.count == 2)
        guard case let .object(first) = output[0] else {
            Issue.record("Expected replay item to be an object")
            return
        }
        #expect(first["type"] == .string("image"))
        guard case let .object(second) = output[1] else {
            Issue.record("Expected replay item to be an object")
            return
        }
        #expect(second["type"] == .string("message"))
        let input = encoded["input"] as? [[String: Any]]
        #expect(encoded["previous_response_id"] as? String == "resp_unknown_output")
        #expect(input?.isEmpty == true)
    }

    @Test
    func opaqueOnlyOutputPersistsResponsesContinuity() async throws {
        let json = """
        {
            "id": "resp_opaque_only",
            "status": "completed",
            "output": [{
                "type": "image",
                "url": "https://example.com/image.png"
            }],
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))
        let message = await client.parseResponse(response)

        #expect(message.content.isEmpty)
        #expect(message.toolCalls.isEmpty)
        #expect(message.reasoningDetails == nil)
        let continuity = try #require(message.continuity)
        guard case let .object(payload) = continuity.payload,
              case let .array(output) = payload["output"]
        else {
            Issue.record("Expected output array in continuity payload")
            return
        }
        #expect(output.count == 1)
        guard case let .object(item) = output[0] else {
            Issue.record("Expected output item to be an object")
            return
        }
        #expect(item["type"] == .string("image"))
    }

    @Test
    func nonStringMessageRoleThrowsDecodingError() async throws {
        let json = """
        {
            "id": "resp_bad_role",
            "status": "completed",
            "output": [{
                "type": "message",
                "role": 123,
                "content": [{"type": "output_text", "text": "Hello"}]
            }],
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let client = makeClient()

        await #expect(throws: AgentError.self) {
            _ = try await client.decodeResponse(Data(json.utf8))
        }
    }

    @Test
    func nonStringOutputTextThrowsDecodingError() async throws {
        let json = """
        {
            "id": "resp_bad_text",
            "status": "completed",
            "output": [{
                "type": "message",
                "content": [{"type": "output_text", "text": 123}]
            }],
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let client = makeClient()

        await #expect(throws: AgentError.self) {
            _ = try await client.decodeResponse(Data(json.utf8))
        }
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

        await #expect(throws: AgentError.llmError(.other("server_error: Internal failure"))) {
            try await client.checkResponseError(response)
        }
    }

    @Test
    func responseWithUnexpectedStatusThrowsLLMError() async throws {
        let json = """
        {
            "id": "resp_008",
            "status": "in_progress",
            "output": [],
            "usage": {"input_tokens": 1, "output_tokens": 1}
        }
        """
        let client = makeClient()
        let response = try await client.decodeResponse(Data(json.utf8))

        await #expect(throws: AgentError.llmError(.other("Unexpected Responses status: in_progress"))) {
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
    func buildURLRequestAppliesAdditionalHeaders() async throws {
        let client = ResponsesAPIClient(
            apiKey: "sk-test-123",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            additionalHeaders: { ["X-Custom-Header": "custom-value"] }
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "X-Custom-Header") == "custom-value")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
    }

    @Test
    func additionalAuthorizationHeaderOverridesApiKeyCaseInsensitively() async throws {
        let client = ResponsesAPIClient(
            apiKey: "sk-test-123",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            additionalHeaders: { ["authorization": "Bearer override"] }
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer override")
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

        #expect(urlRequest.url?.absoluteString == "https://custom.api.com/v2/custom/responses")
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
            extraFields: [
                "z_custom_field": .string("bad"),
                "custom_field": .string("bad"),
                "temperature": .double(0.7),
            ]
        )

        do {
            _ = try JSONEncoder().encode(request)
            Issue.record("Expected EncodingError")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(context.debugDescription == "Invalid extraFields for Responses API: custom_field, z_custom_field")
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
            #expect(context.debugDescription == "Invalid extraFields for Responses API: model")
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
