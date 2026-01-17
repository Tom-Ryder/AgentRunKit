import Foundation
import Testing

@testable import AgentRunKit

actor MockLLMClient: LLMClient {
    private let responses: [AssistantMessage]
    private var callIndex: Int = 0

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite
struct MockLLMClientTests {
    @Test
    func returnsResponses() async throws {
        let client = MockLLMClient(responses: [AssistantMessage(content: "Hello!")])
        let response = try await client.generate(messages: [], tools: [])
        #expect(response.content == "Hello!")
    }

    @Test
    func returnsMultipleResponses() async throws {
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "First"),
            AssistantMessage(content: "Second")
        ])
        let first = try await client.generate(messages: [], tools: [])
        let second = try await client.generate(messages: [], tools: [])
        #expect(first.content == "First")
        #expect(second.content == "Second")
    }

    @Test
    func throwsWhenExhausted() async throws {
        let client = MockLLMClient(responses: [])
        do {
            _ = try await client.generate(messages: [], tools: [])
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case .llmError = error else {
                Issue.record("Expected llmError, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected llmError, got \(error)")
        }
    }
}

@Suite
struct ToolDefinitionTests {
    @Test
    func createsFromTool() throws {
        let tool = try Tool<TestParams, TestOutput, EmptyContext>(
            name: "double",
            description: "Doubles a value",
            executor: { params, _ in TestOutput(result: params.value * 2) }
        )
        let def = ToolDefinition(tool)
        #expect(def.name == "double")
        #expect(def.description == "Doubles a value")
        guard case let .object(props, required, _) = def.parametersSchema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(required == ["value"])
        #expect(props["value"] != nil)
    }
}

@Suite
struct OpenAIClientRequestTests {
    @Test
    func requestEncodesCorrectly() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            maxTokens: 1000,
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [
            .system("You are helpful"),
            .user("Hello")
        ]
        let tools = [
            ToolDefinition(
                name: "get_weather",
                description: "Get weather",
                parametersSchema: .object(properties: ["city": .string()], required: ["city"])
            )
        ]

        let request = client.buildRequest(messages: messages, tools: tools)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["model"] as? String == "test/model")
        #expect(json?["max_tokens"] as? Int == 1000)
        #expect(json?["tool_choice"] as? String == "auto")

        let jsonMessages = json?["messages"] as? [[String: Any]]
        #expect(jsonMessages?.count == 2)
        #expect(jsonMessages?[0]["role"] as? String == "system")
        #expect(jsonMessages?[0]["content"] as? String == "You are helpful")
        #expect(jsonMessages?[1]["role"] as? String == "user")
        #expect(jsonMessages?[1]["content"] as? String == "Hello")

        let jsonTools = json?["tools"] as? [[String: Any]]
        #expect(jsonTools?.count == 1)
        #expect(jsonTools?[0]["type"] as? String == "function")
        let function = jsonTools?[0]["function"] as? [String: Any]
        #expect(function?["name"] as? String == "get_weather")
        #expect(function?["description"] as? String == "Get weather")
    }

    @Test
    func requestWithoutToolsOmitsToolFields() throws {
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["tools"] == nil)
        #expect(json?["tool_choice"] == nil)
    }

    @Test
    func requestEncodesAudioParts() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let audioData = Data("audio".utf8)
        let messages: [ChatMessage] = [
            .user([.text("Transcribe"), .audio(data: audioData, format: .wav)])
        ]
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let content = jsonMessages?.first?["content"] as? [[String: Any]]
        let textPart = content?.first { $0["type"] as? String == "text" }
        #expect(textPart?["text"] as? String == "Transcribe")
        let audioPart = content?.first { $0["type"] as? String == "input_audio" }
        #expect(audioPart?["type"] as? String == "input_audio")
        let inputAudio = audioPart?["input_audio"] as? [String: Any]
        #expect(inputAudio?["format"] as? String == "wav")
        #expect(inputAudio?["data"] as? String == audioData.base64EncodedString())
    }

    @Test
    func assistantMessageWithToolCallsEncodes() throws {
        let toolCall = ToolCall(id: "call_123", name: "get_weather", arguments: "{\"city\":\"NYC\"}")
        let assistantMsg = AssistantMessage(content: "Let me check", toolCalls: [toolCall])
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        #expect(jsonMessages?.count == 1)
        let msg = jsonMessages?[0]
        #expect(msg?["role"] as? String == "assistant")
        #expect(msg?["content"] as? String == "Let me check")

        let jsonToolCalls = msg?["tool_calls"] as? [[String: Any]]
        #expect(jsonToolCalls?.count == 1)
        #expect(jsonToolCalls?[0]["id"] as? String == "call_123")
        #expect(jsonToolCalls?[0]["type"] as? String == "function")
        let function = jsonToolCalls?[0]["function"] as? [String: Any]
        #expect(function?["name"] as? String == "get_weather")
        #expect(function?["arguments"] as? String == "{\"city\":\"NYC\"}")
    }

    @Test
    func toolResultMessageEncodes() throws {
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [
            .tool(id: "call_123", name: "get_weather", content: "{\"temp\": 72}")
        ]
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["role"] as? String == "tool")
        #expect(msg?["tool_call_id"] as? String == "call_123")
        #expect(msg?["name"] as? String == "get_weather")
        #expect(msg?["content"] as? String == "{\"temp\": 72}")
    }
}

@Suite
struct TransportErrorTests {
    @Test
    func errorsAreEquatable() {
        #expect(TransportError.invalidResponse == TransportError.invalidResponse)
        #expect(TransportError.noChoices == TransportError.noChoices)
        let err400 = TransportError.httpError(statusCode: 400, body: "bad")
        let err401 = TransportError.httpError(statusCode: 401, body: "bad")
        #expect(err400 == err400)
        #expect(err400 != err401)
    }
}

@Suite
struct OpenAIClientInitTests {
    @Test
    func defaultMaxTokensIs16k() {
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openAIBaseURL)
        #expect(client.maxTokens == 16384)
    }

    @Test
    func customMaxTokensIsRespected() {
        let client = OpenAIClient(apiKey: "test", model: "test", maxTokens: 4096, baseURL: OpenAIClient.openAIBaseURL)
        #expect(client.maxTokens == 4096)
    }
}

@Suite
struct OpenAIClientURLRequestTests {
    @Test
    func buildURLRequestSetsCorrectProperties() throws {
        let client = OpenAIClient(
            apiKey: "sk-test-key-123",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(messages: messages, tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key-123")
    }

    @Test
    func buildURLRequestWithCustomBaseURL() throws {
        guard let customURL = URL(string: "https://custom.api.example.com/v2") else {
            Issue.record("Failed to create custom URL")
            return
        }
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: customURL)
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(messages: messages, tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://custom.api.example.com/v2/chat/completions")
    }

    @Test
    func buildTranscriptionURLRequestEncodesMultipartBody() {
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openAIBaseURL)
        let audioData = Data("audio-data".utf8)
        let urlRequest = client.buildTranscriptionURLRequest(
            audio: audioData,
            format: .wav,
            model: "whisper-1",
            options: TranscriptionOptions(language: "en", prompt: "Hello", temperature: 0.2),
            boundary: "boundary"
        )

        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=boundary")

        guard let body = urlRequest.httpBody else {
            Issue.record("Expected httpBody to be set")
            return
        }

        let parts = parseMultipartBody(body, boundary: "boundary")
        #expect(parts.count == 5)

        let modelPart = multipartPart(named: "model", parts: parts)
        #expect(modelPart?.body == "whisper-1")

        let languagePart = multipartPart(named: "language", parts: parts)
        #expect(languagePart?.body == "en")

        let promptPart = multipartPart(named: "prompt", parts: parts)
        #expect(promptPart?.body == "Hello")

        let temperaturePart = multipartPart(named: "temperature", parts: parts)
        #expect(temperaturePart?.body == "0.2")

        let filePart = multipartPart(named: "file", parts: parts)
        #expect(filePart?.headers["Content-Type"] == "audio/wav")
        #expect(filePart?.body == "audio-data")
        #expect(filePart?.filename == "audio.wav")
    }

    @Test
    func buildTranscriptionURLRequestOmitsOptionalFields() {
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openAIBaseURL)
        let audioData = Data("audio-data".utf8)
        let urlRequest = client.buildTranscriptionURLRequest(
            audio: audioData,
            format: .wav,
            model: "whisper-1",
            options: TranscriptionOptions(),
            boundary: "boundary"
        )

        guard let body = urlRequest.httpBody else {
            Issue.record("Expected httpBody to be set")
            return
        }

        let parts = parseMultipartBody(body, boundary: "boundary")
        #expect(parts.count == 2)
        #expect(multipartPart(named: "model", parts: parts)?.body == "whisper-1")
        #expect(multipartPart(named: "file", parts: parts)?.body == "audio-data")
        #expect(multipartPart(named: "language", parts: parts) == nil)
        #expect(multipartPart(named: "prompt", parts: parts) == nil)
        #expect(multipartPart(named: "temperature", parts: parts) == nil)
    }

    @Test
    func buildTranscriptionURLRequestWithFileBody() throws {
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openAIBaseURL)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftagent-audio-\(UUID().uuidString).wav")
        let audioData = Data("audio-data".utf8)
        try audioData.write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let (urlRequest, bodyURL) = try client.buildTranscriptionURLRequest(
            audioFileURL: audioURL,
            format: .wav,
            model: "whisper-1",
            options: TranscriptionOptions(),
            boundary: "boundary"
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        #expect(urlRequest.httpBody == nil)
        let body = try Data(contentsOf: bodyURL)
        let parts = parseMultipartBody(body, boundary: "boundary")
        #expect(parts.count == 2)
        #expect(multipartPart(named: "model", parts: parts)?.body == "whisper-1")
        #expect(multipartPart(named: "file", parts: parts)?.body == "audio-data")
    }
}

@Suite
struct ReasoningConfigTests {
    @Test
    func initialization() {
        let config = ReasoningConfig(effort: .high)
        #expect(config.effort == .high)
    }

    @Test
    func staticFactories() {
        #expect(ReasoningConfig.high.effort == .high)
        #expect(ReasoningConfig.medium.effort == .medium)
        #expect(ReasoningConfig.low.effort == .low)
    }

    @Test
    func effortRawValues() {
        #expect(ReasoningConfig.Effort.xhigh.rawValue == "xhigh")
        #expect(ReasoningConfig.Effort.high.rawValue == "high")
        #expect(ReasoningConfig.Effort.medium.rawValue == "medium")
        #expect(ReasoningConfig.Effort.low.rawValue == "low")
        #expect(ReasoningConfig.Effort.minimal.rawValue == "minimal")
        #expect(ReasoningConfig.Effort.none.rawValue == "none")
    }

    @Test
    func equatability() {
        let config1 = ReasoningConfig(effort: .high)
        let config2 = ReasoningConfig(effort: .high)
        let config3 = ReasoningConfig(effort: .low)
        #expect(config1 == config2)
        #expect(config1 != config3)
    }
}

@Suite
struct ReasoningRequestEncodingTests {
    @Test
    func requestIncludesReasoningEffort() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: .high
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["reasoning_effort"] as? String == "high")
    }

    @Test
    func requestOmitsReasoningEffortWhenNil() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["reasoning_effort"] == nil)
    }

    @Test
    func requestEncodesAllEffortLevels() throws {
        for effort in [ReasoningConfig.Effort.xhigh, .high, .medium, .low, .minimal, .none] {
            let config = ReasoningConfig(effort: effort)
            let client = OpenAIClient(
                apiKey: "test-key",
                model: "test/model",
                baseURL: OpenAIClient.openRouterBaseURL,
                reasoningConfig: config
            )
            let messages: [ChatMessage] = [.user("Hello")]
            let request = client.buildRequest(messages: messages, tools: [])

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            #expect(json?["reasoning_effort"] as? String == effort.rawValue)
        }
    }
}

@Suite
struct ReasoningMultiTurnTests {
    @Test
    func assistantMessageWithReasoningEncodes() throws {
        let reasoning = ReasoningContent(content: "Let me think about this...")
        let assistantMsg = AssistantMessage(content: "The answer is 42", reasoning: reasoning)
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["role"] as? String == "assistant")
        #expect(msg?["content"] as? String == "The answer is 42")
        #expect(msg?["reasoning_content"] as? String == "Let me think about this...")
    }

    @Test
    func assistantMessageWithoutReasoningOmitsField() throws {
        let assistantMsg = AssistantMessage(content: "The answer is 42")
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["reasoning_content"] == nil)
    }

    @Test
    func assistantMessageWithToolCallsAndReasoningEncodes() throws {
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
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["reasoning_content"] as? String == "I need to check the weather...")
        let jsonToolCalls = msg?["tool_calls"] as? [[String: Any]]
        #expect(jsonToolCalls?.count == 1)
    }
}
