import Foundation
import Testing

@testable import AgentRunKit

private func encodeRequest(_ request: GeminiRequest) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
    guard let dict = object as? [String: Any] else {
        preconditionFailure("Encoded request is not a JSON object: \(object)")
    }
    return dict
}

// MARK: - Request Serialization Tests

@Suite
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

        let system = json["system_instruction"] as? [String: Any]
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

        let system = json["system_instruction"] as? [String: Any]
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

        #expect(json["system_instruction"] == nil)
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
        let decls = jsonTools?[0]["function_declarations"] as? [[String: Any]]
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
        #expect(json["tool_config"] == nil)
    }

    @Test
    func maxOutputTokensEncodes() throws {
        let client = makeClient(maxOutputTokens: 4096)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generation_config"] as? [String: Any]
        #expect(genConfig?["maxOutputTokens"] as? Int == 4096)
    }

    @Test
    func thinkingConfigEncodes() throws {
        let client = makeClient(reasoningConfig: .high)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generation_config"] as? [String: Any]
        let thinking = genConfig?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["includeThoughts"] as? Bool == true)
        #expect(thinking?["thinkingLevel"] as? String == "HIGH")
    }

    @Test
    func noReasoningOmitsThinkingConfig() throws {
        let client = makeClient()
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generation_config"] as? [String: Any]
        #expect(genConfig?["thinkingConfig"] == nil)
    }

    @Test
    func noneEffortOmitsThinkingConfig() throws {
        let client = makeClient(reasoningConfig: ReasoningConfig.none)
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generation_config"] as? [String: Any]
        #expect(genConfig?["thinkingConfig"] == nil)
    }

    @Test
    func explicitBudgetTokensEncodes() throws {
        let client = makeClient(reasoningConfig: .budget(10000))
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generation_config"] as? [String: Any]
        let thinking = genConfig?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["includeThoughts"] as? Bool == true)
        #expect(thinking?["thinkingBudget"] as? Int == 10000)
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

        let toolConfig = json["tool_config"] as? [String: Any]
        let funcConfig = toolConfig?["function_calling_config"] as? [String: Any]
        #expect(funcConfig?["mode"] as? String == "AUTO")
    }
}

// MARK: - URL Request Tests

@Suite
struct GeminiURLRequestTests {
    @Test
    func setsCorrectURL() throws {
        let client = GeminiClient(
            apiKey: "test-api-key-123",
            model: "gemini-2.5-pro"
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildURLRequest(request, stream: false)

        let url = urlRequest.url!
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

        let url = urlRequest.url!
        #expect(url.path.contains("models/gemini-2.5-pro:streamGenerateContent"))
        #expect(url.query?.contains("alt=sse") == true)
        #expect(url.query?.contains("key=test-key") == true)
    }

    @Test
    func customBaseURL() throws {
        let client = GeminiClient(
            apiKey: "test-key",
            model: "gemini-2.5-flash",
            baseURL: URL(string: "https://custom.api.example.com")!
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

// MARK: - Response Parsing Tests

@Suite
struct GeminiResponseParsingTests {
    private func makeClient() -> GeminiClient {
        GeminiClient(apiKey: "test-key", model: "gemini-2.5-pro")
    }

    @Test
    func textResponse() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [{"text": "Hello there!"}]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 100,
                "candidatesTokenCount": 50,
                "totalTokenCount": 150
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "Hello there!")
        #expect(msg.toolCalls.isEmpty)
        #expect(msg.tokenUsage?.input == 100)
        #expect(msg.tokenUsage?.output == 50)
    }

    @Test
    func functionCallResponse() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"text": "Let me check."},
                        {"functionCall": {"id": "call_01", "name": "get_weather", "args": {"city": "NYC"}}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 30
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "Let me check.")
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "call_01")
        #expect(msg.toolCalls[0].name == "get_weather")
        #expect(msg.toolCalls[0].arguments.contains("NYC"))
    }

    @Test
    func thinkingResponse() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"text": "Let me reason...", "thought": true, "thoughtSignature": "sig123"},
                        {"text": "The answer is 42."}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 100,
                "candidatesTokenCount": 200,
                "thoughtsTokenCount": 50
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "The answer is 42.")
        #expect(msg.reasoning?.content == "Let me reason...")
        #expect(msg.reasoningDetails?.count == 1)
        if case let .object(dict) = msg.reasoningDetails?[0] {
            #expect(dict["type"] == .string("thinking"))
            #expect(dict["thinking"] == .string("Let me reason..."))
            #expect(dict["signature"] == .string("sig123"))
        } else {
            Issue.record("Expected object in reasoning details")
        }
        #expect(msg.tokenUsage?.reasoning == 50)
        #expect(msg.tokenUsage?.output == 150)
    }

    @Test
    func multipleFunctionCalls() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"functionCall": {"id": "call_a", "name": "search", "args": {"q": "first"}}},
                        {"functionCall": {"id": "call_b", "name": "lookup", "args": {"id": 42}}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 30
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.toolCalls.count == 2)
        #expect(msg.toolCalls[0].id == "call_a")
        #expect(msg.toolCalls[0].name == "search")
        #expect(msg.toolCalls[1].id == "call_b")
        #expect(msg.toolCalls[1].name == "lookup")
    }

    @Test
    func functionCallWithoutId() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"functionCall": {"name": "get_weather", "args": {"city": "NYC"}}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 30
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "gemini_call_0")
        #expect(msg.toolCalls[0].name == "get_weather")
    }

    @Test
    func errorResponse() throws {
        let json = """
        {
            "error": {
                "code": 400,
                "message": "Invalid request",
                "status": "INVALID_ARGUMENT"
            }
        }
        """
        do {
            _ = try makeClient().parseResponse(Data(json.utf8))
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .other(msg) = transport
            else {
                Issue.record("Expected .other, got \(error)")
                return
            }
            #expect(msg.contains("INVALID_ARGUMENT"))
            #expect(msg.contains("Invalid request"))
        }
    }

    @Test
    func usageMapping() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [{"text": "Hi"}]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 200,
                "candidatesTokenCount": 100
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.tokenUsage == TokenUsage(input: 200, output: 100))
    }

    @Test
    func emptyCandidatesThrows() {
        let json = """
        {
            "candidates": [],
            "usageMetadata": {
                "promptTokenCount": 10,
                "candidatesTokenCount": 0
            }
        }
        """
        #expect(throws: AgentError.self) {
            _ = try makeClient().parseResponse(Data(json.utf8))
        }
    }

    @Test
    func emptyContentParsesToEmptyString() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": []
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 10,
                "candidatesTokenCount": 0
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "")
        #expect(msg.toolCalls.isEmpty)
    }

    @Test
    func interleavedThinkingAndFunctionCall() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"text": "Think first", "thought": true, "thoughtSignature": "s1"},
                        {"text": "Checking."},
                        {"functionCall": {"id": "call_02", "name": "search", "args": {"q": "test"}}},
                        {"text": "Think again", "thought": true, "thoughtSignature": "s2"},
                        {"text": "More text."}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 80,
                "candidatesTokenCount": 120,
                "thoughtsTokenCount": 40
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "Checking.More text.")
        #expect(msg.toolCalls.count == 1)
        #expect(msg.reasoning?.content == "Think first\nThink again")
        #expect(msg.reasoningDetails?.count == 2)
        #expect(msg.tokenUsage?.reasoning == 40)
        #expect(msg.tokenUsage?.output == 80)
    }

    @Test
    func cachedContentTokenCountMappedToCacheRead() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [{"text": "Hi"}]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 200,
                "candidatesTokenCount": 100,
                "cachedContentTokenCount": 150
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.tokenUsage?.cacheRead == 150)
    }

    @Test
    func functionCallWithoutArgs() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"functionCall": {"id": "call_01", "name": "get_status"}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 10
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].arguments == "{}")
    }

    @Test
    func malformedResponseThrowsDecodingError() {
        let client = makeClient()
        let garbage = Data("not json at all".utf8)

        #expect(throws: AgentError.self) {
            _ = try client.parseResponse(garbage)
        }
    }

    @Test
    func toolCallArgumentsRoundTripAsJSONObject() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"functionCall": {"id": "call_rt", "name": "get_weather",
                         "args": {"city": "NYC", "units": "celsius"}}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 40,
                "candidatesTokenCount": 20
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "call_rt")
        #expect(msg.toolCalls[0].name == "get_weather")

        let parsedArgs = try JSONDecoder().decode(
            [String: String].self, from: Data(msg.toolCalls[0].arguments.utf8)
        )
        #expect(parsedArgs["city"] == "NYC")
        #expect(parsedArgs["units"] == "celsius")

        let (_, mapped) = try GeminiMessageMapper.mapMessages([.assistant(msg)])
        let modelParts = mapped[0].parts
        let toolPart = modelParts.first { $0.functionCall != nil }
        #expect(toolPart?.functionCall?.id == "call_rt")
        #expect(toolPart?.functionCall?.name == "get_weather")
        guard case let .object(inputDict) = toolPart?.functionCall?.args else {
            Issue.record("Expected args to be a JSON object")
            return
        }
        #expect(inputDict["city"] == .string("NYC"))
        #expect(inputDict["units"] == .string("celsius"))
    }
}

// MARK: - Message Mapper Tests

@Suite
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

@Suite
struct GeminiResponseFormatTests {
    @Test
    func responseFormatEncodesInGenerationConfig() throws {
        let client = GeminiClient(apiKey: "k", model: "m")
        let format = ResponseFormat.jsonSchema(TestGeminiOutput.self)
        let request = try client.buildRequest(
            messages: [.user("Hi")], tools: [], responseFormat: format
        )
        let json = try encodeRequest(request)

        let genConfig = json["generation_config"] as? [String: Any]
        #expect(genConfig?["responseMimeType"] as? String == "application/json")
        #expect(genConfig?["responseJsonSchema"] != nil)
    }

    @Test
    func noResponseFormatOmitsFields() throws {
        let client = GeminiClient(apiKey: "k", model: "m")
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        let genConfig = json["generation_config"] as? [String: Any]
        #expect(genConfig?["responseMimeType"] == nil)
        #expect(genConfig?["responseJsonSchema"] == nil)
    }
}

private enum TestGeminiOutput: SchemaProviding {
    static var jsonSchema: JSONSchema { .object(properties: ["value": .string()], required: ["value"]) }
}
