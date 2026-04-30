@testable import AgentRunKit
import Foundation
import Testing

private actor FallbackRequestModeMockLLMClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("FallbackRequestModeMockLLMClient")
    private let response: AssistantMessage
    private(set) var generateCallCount = 0

    init(response: AssistantMessage) {
        self.response = response
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        generateCallCount += 1
        return response
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let (stream, continuation) = AsyncThrowingStream<StreamDelta, Error>.makeStream()
        continuation.yield(.content("fallback"))
        continuation.finish()
        return stream
    }
}

struct LLMClientRequestModeTests {
    @Test
    func generateForRunFallsBackToPlainGenerate() async throws {
        let client = FallbackRequestModeMockLLMClient(
            response: AssistantMessage(content: "hello")
        )

        let response = try await client.generateForRun(
            messages: [.user("Hi")],
            tools: [],
            responseFormat: nil,
            requestContext: nil,
            requestMode: .forceFullRequest
        )

        #expect(response.content == "hello")
        #expect(await client.generateCallCount == 1)
    }

    @Test
    func streamForRunFallsBackToPlainStream() async throws {
        let client = FallbackRequestModeMockLLMClient(
            response: AssistantMessage(content: "")
        )

        var collected = ""
        for try await element in client.streamForRun(
            messages: [.user("Hi")],
            tools: [],
            requestContext: nil,
            requestMode: .forceFullRequest
        ) {
            if case let .delta(.content(text)) = element {
                collected += text
            }
        }

        #expect(collected == "fallback")
    }
}

private let malformedToolHistory: [ChatMessage] = [
    .user("Hi"),
    .assistant(AssistantMessage(
        content: "",
        toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
    )),
]

/// @unchecked Sendable justification: URLProtocol is Foundation infrastructure and has no
/// shared mutable state.
private final class CancelledUploadURLProtocol: URLProtocol, @unchecked Sendable {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelledUploadURLProtocol.self]
        return configuration
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}

struct ProviderHistoryValidationTests {
    private func assertGenerateRejectsMalformedHistory(client: any LLMClient) async {
        await #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
            _ = try await client.generate(
                messages: malformedToolHistory,
                tools: [],
                responseFormat: nil,
                requestContext: nil
            )
        }
    }

    private func assertStreamRejectsMalformedHistory(client: any LLMClient) async {
        await #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
            for try await _ in client.stream(messages: malformedToolHistory, tools: [], requestContext: nil) {}
        }
    }

    @Test
    func openAIBoundariesRejectMalformedHistory() async {
        let client = OpenAIClient(apiKey: "test-key", model: "test-model", baseURL: OpenAIClient.openAIBaseURL)
        await assertGenerateRejectsMalformedHistory(client: client)
        await assertStreamRejectsMalformedHistory(client: client)
    }

    @Test
    func anthropicBoundariesRejectMalformedHistory() async throws {
        let client = try AnthropicClient(apiKey: "test-key", model: "test-model")
        await assertGenerateRejectsMalformedHistory(client: client)
        await assertStreamRejectsMalformedHistory(client: client)
    }

    @Test
    func geminiBoundariesRejectMalformedHistory() async {
        let client = GeminiClient(apiKey: "test-key", model: "test-model")
        await assertGenerateRejectsMalformedHistory(client: client)
        await assertStreamRejectsMalformedHistory(client: client)
    }

    @Test
    func responsesBoundariesRejectMalformedHistory() async {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "test-model",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: false
        )
        await assertGenerateRejectsMalformedHistory(client: client)
        await assertStreamRejectsMalformedHistory(client: client)
    }
}

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

        let request = try client.buildRequest(messages: messages, tools: tools)
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
    func firstPartyOpenAIEncodesMaxCompletionTokens() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "gpt-5.4-mini",
            maxTokens: 2048,
            baseURL: OpenAIClient.openAIBaseURL,
            profile: .firstParty
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["max_completion_tokens"] as? Int == 2048)
        #expect(json?["max_tokens"] == nil)
    }

    @Test
    func thirdPartyEncodesMaxTokens() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            maxTokens: 1024,
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["max_tokens"] as? Int == 1024)
        #expect(json?["max_completion_tokens"] == nil)
    }

    @Test
    func requestWithoutToolsOmitsToolFields() throws {
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])

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
        let request = try client.buildRequest(messages: messages, tools: [])

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
        let request = try client.buildRequest(messages: messages, tools: [])

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
    func assistantMessageWithEmptyContentEncodesAsEmptyString() throws {
        let assistantMsg = AssistantMessage(content: "")
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["content"] as? String == "")
        #expect(msg?["content"] is String)
    }

    @Test
    func assistantMessageWithToolCallsAndEmptyContentEncodesAsEmptyString() throws {
        let toolCall = ToolCall(id: "call_abc", name: "list_gyms", arguments: "{}")
        let assistantMsg = AssistantMessage(content: "", toolCalls: [toolCall])
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        let msg = jsonMessages?[0]
        #expect(msg?["content"] as? String == "")
        #expect(msg?["content"] is String)
        let jsonToolCalls = msg?["tool_calls"] as? [[String: Any]]
        #expect(jsonToolCalls?.count == 1)
    }

    @Test
    func assistantContentNeverEncodesAsNull() throws {
        let toolCall = ToolCall(id: "call_xyz", name: "search", arguments: "{\"q\":\"test\"}")
        let assistantMsg = AssistantMessage(content: "", toolCalls: [toolCall])
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [.assistant(assistantMsg)]
        let request = try client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        #expect(!jsonString.contains("\"content\":null"))
        #expect(jsonString.contains("\"content\":\"\""))
    }

    @Test
    func fullToolCallConversationEncodesCorrectly() throws {
        let toolCall = ToolCall(id: "call_abc123", name: "list_gyms", arguments: "{}")
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [
            .system("You are a helpful assistant."),
            .user("What gyms do I have?"),
            .assistant(AssistantMessage(content: "", toolCalls: [toolCall])),
            .tool(id: "call_abc123", name: "list_gyms", content: "[{\"id\":\"gym1\",\"name\":\"My Gym\"}]")
        ]
        let request = try client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        #expect(jsonMessages?.count == 4)

        let assistantMsg = jsonMessages?[2]
        #expect(assistantMsg?["role"] as? String == "assistant")
        #expect(assistantMsg?["content"] as? String == "")
        #expect(assistantMsg?["content"] is String)

        let toolMsg = jsonMessages?[3]
        #expect(toolMsg?["role"] as? String == "tool")
        #expect(toolMsg?["tool_call_id"] as? String == "call_abc123")
    }

    @Test
    func multipleToolCallsWithEmptyContentEncodes() throws {
        let call1 = ToolCall(id: "call_1", name: "get_weather", arguments: "{\"city\":\"NYC\"}")
        let call2 = ToolCall(id: "call_2", name: "get_time", arguments: "{\"tz\":\"EST\"}")
        let assistantMsg = AssistantMessage(content: "", toolCalls: [call1, call2])
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [
            .user("What's the weather and time in NYC?"),
            .assistant(assistantMsg),
            .tool(id: "call_1", name: "get_weather", content: "{\"temp\":72}"),
            .tool(id: "call_2", name: "get_time", content: "{\"time\":\"3:00 PM\"}")
        ]
        let request = try client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonMessages = json?["messages"] as? [[String: Any]]
        #expect(jsonMessages?.count == 4)

        let assistantMsgJson = jsonMessages?[1]
        #expect(assistantMsgJson?["content"] as? String == "")
        let toolCalls = assistantMsgJson?["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.count == 2)
    }

    @Test
    func toolResultMessageEncodes() throws {
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: OpenAIClient.openRouterBaseURL)
        let messages: [ChatMessage] = [
            .tool(id: "call_123", name: "get_weather", content: "{\"temp\": 72}")
        ]
        let request = try client.buildRequest(messages: messages, tools: [])

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

struct OpenAIClientURLRequestTests {
    @Test
    func buildURLRequestSetsCorrectProperties() throws {
        let client = OpenAIClient(
            apiKey: "sk-test-key-123",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key-123")
    }

    @Test
    func additionalAuthorizationHeaderOverridesApiKeyCaseInsensitively() throws {
        let client = OpenAIClient(
            apiKey: "sk-test-key-123",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL,
            additionalHeaders: { ["authorization": "Bearer override"] }
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer override")
    }

    @Test
    func buildURLRequestWithCustomBaseURL() throws {
        guard let customURL = URL(string: "https://custom.api.example.com/v2") else {
            Issue.record("Failed to create custom URL")
            return
        }
        let client = OpenAIClient(apiKey: "test-key", model: "test/model", baseURL: customURL)
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])
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
            boundary: "boundary",
            apiKey: "test-key"
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
            boundary: "boundary",
            apiKey: "test-key"
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
            boundary: "boundary",
            apiKey: "test-key"
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        #expect(urlRequest.httpBody == nil)
        let body = try Data(contentsOf: bodyURL)
        let parts = parseMultipartBody(body, boundary: "boundary")
        #expect(parts.count == 2)
        #expect(multipartPart(named: "model", parts: parts)?.body == "whisper-1")
        #expect(multipartPart(named: "file", parts: parts)?.body == "audio-data")
    }

    @Test
    func transcribeFileUploadCancellationPropagatesCancellationError() async throws {
        let session = URLSession(configuration: CancelledUploadURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client = try OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: #require(URL(string: "https://cancelled-upload.test/v1")),
            session: session
        )
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftagent-cancelled-upload-\(UUID().uuidString).wav")
        try Data("audio-data".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await client.transcribe(
                audioFileURL: audioURL,
                format: .wav,
                model: "whisper-1"
            )
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }
}

struct ReasoningConfigTests {
    @Test
    func initialization() {
        let config = ReasoningConfig(effort: .high)
        #expect(config.effort == .high)
        #expect(config.maxTokens == nil)
        #expect(config.exclude == nil)
    }

    @Test
    func initializationWithAllFields() {
        let config = ReasoningConfig(effort: .medium, maxTokens: 8192, exclude: true)
        #expect(config.effort == .medium)
        #expect(config.maxTokens == 8192)
        #expect(config.exclude == true)
    }

    @Test
    func staticFactories() {
        #expect(ReasoningConfig.high.effort == .high)
        #expect(ReasoningConfig.high.maxTokens == nil)
        #expect(ReasoningConfig.high.exclude == nil)
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

    @Test
    func equatabilityWithMaxTokens() {
        let config1 = ReasoningConfig(effort: .high, maxTokens: 8192)
        let config2 = ReasoningConfig(effort: .high, maxTokens: 8192)
        let config3 = ReasoningConfig(effort: .high, maxTokens: 4096)
        #expect(config1 == config2)
        #expect(config1 != config3)
    }

    @Test
    func equatabilityWithExclude() {
        let config1 = ReasoningConfig(effort: .high, exclude: true)
        let config2 = ReasoningConfig(effort: .high, exclude: true)
        let config3 = ReasoningConfig(effort: .high, exclude: false)
        #expect(config1 == config2)
        #expect(config1 != config3)
    }
}

struct ProxyModeTests {
    @Test
    func proxyFactoryCreatesClientWithoutApiKeyOrModel() throws {
        let client = try OpenAIClient.proxy(baseURL: #require(URL(string: "http://localhost:8080")))
        #expect(client.modelIdentifier == nil)
        #expect(client.maxTokens == 16384)
    }

    @Test
    func proxyRequestOmitsAuthorizationHeader() throws {
        let client = try OpenAIClient.proxy(baseURL: #require(URL(string: "http://localhost:8080")))
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func proxyRequestOmitsModelFromBody() throws {
        let client = try OpenAIClient.proxy(baseURL: #require(URL(string: "http://localhost:8080")))
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["model"] == nil)
        #expect(json?["messages"] != nil)
    }

    @Test
    func proxyWithAdditionalHeaders() throws {
        let client = try OpenAIClient.proxy(
            baseURL: #require(URL(string: "http://localhost:8080")),
            additionalHeaders: { ["X-Custom-Header": "custom-value"] }
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "X-Custom-Header") == "custom-value")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func clientWithApiKeyIncludesAuthorizationHeader() throws {
        let client = try OpenAIClient(apiKey: "test-key", baseURL: #require(URL(string: "http://localhost:8080")))
        let messages: [ChatMessage] = [.user("Hello")]
        let request = try client.buildRequest(messages: messages, tools: [])
        let urlRequest = try client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test
    func transcribeThrowsWhenApiKeyNil() async throws {
        let client = try OpenAIClient.proxy(baseURL: #require(URL(string: "http://localhost:8080")))

        await #expect(throws: AgentError.self) {
            _ = try await client.transcribe(audio: Data(), format: .wav, model: "whisper-1")
        }
    }
}

private actor LineCounter {
    private(set) var count = 0
    func increment() {
        count += 1
    }
}

struct StreamStallDetectionTests {
    private func sseChunk(_ json: String) -> [UInt8] {
        Array("data: \(json)\n\n".utf8)
    }

    private func sseDone() -> [UInt8] {
        Array("data: [DONE]\n\n".utf8)
    }

    private let minimalChunkJSON = """
    {"choices":[{"delta":{"content":"hello"},"index":0}]}
    """

    @Test
    func stalledStreamThrowsError() async throws {
        let (byteStream, continuation) = AsyncStream<UInt8>.makeStream()

        for byte in sseChunk(minimalChunkJSON) {
            continuation.yield(byte)
        }

        let controlled = ControlledByteStream(stream: byteStream)

        let started = ContinuousClock.now
        do {
            try await processSSEStream(
                bytes: controlled,
                stallTimeout: .milliseconds(500)
            ) { _, _ in false }
            Issue.record("Expected idle timeout error")
        } catch let error as AgentError {
            let elapsed = ContinuousClock.now - started
            guard case let .llmError(transport) = error else {
                Issue.record("Expected llmError, got \(error)")
                return
            }
            guard case let .streamFailed(.idleTimeout(diagnostics)) = transport else {
                Issue.record("Expected idle timeout, got \(transport)")
                return
            }
            #expect(diagnostics.eventsObserved == 1)
            #expect(elapsed >= .milliseconds(450))
            #expect(elapsed < .seconds(2))
            #expect(diagnostics.elapsed >= .milliseconds(450))
            #expect(diagnostics.elapsed < .seconds(2))
        }
    }

    @Test
    func cancelledSSEStreamPropagatesCancellation() async throws {
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()
        let controlled = ControlledByteStream(stream: byteStream)
        let task = Task {
            try await processSSEStream(
                bytes: controlled,
                stallTimeout: .seconds(5)
            ) { _, _ in false }
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        byteContinuation.finish()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func healthyStreamCompletesWithStallDetection() async throws {
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()

        for byte in sseChunk(minimalChunkJSON) + sseDone() {
            byteContinuation.yield(byte)
        }
        byteContinuation.finish()

        let controlled = ControlledByteStream(stream: byteStream)
        let counter = LineCounter()

        try await processSSEStream(
            bytes: controlled,
            stallTimeout: .seconds(5)
        ) { event, _ in
            await counter.increment()
            return event.data == "[DONE]"
        }

        let total = await counter.count
        #expect(total >= 2)
    }

    @Test
    func streamEndingBeforeHandlerCompletionThrowsProviderTerminationMissing() async throws {
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()

        for byte in sseChunk(minimalChunkJSON) {
            byteContinuation.yield(byte)
        }
        byteContinuation.finish()

        let controlled = ControlledByteStream(stream: byteStream)

        do {
            try await processSSEStream(
                bytes: controlled,
                stallTimeout: nil
            ) { _, _ in false }
            Issue.record("Expected provider termination missing")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.providerTerminationMissing(diagnostics))) = error else {
                Issue.record("Expected provider termination missing, got \(error)")
                return
            }
            #expect(diagnostics.eventsObserved == 1)
        }
    }

    @Test
    func streamEndingBeforeHandlerCompletionThrowsProviderTerminationMissingWithStallDetection() async throws {
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()

        for byte in sseChunk(minimalChunkJSON) {
            byteContinuation.yield(byte)
        }
        byteContinuation.finish()

        let controlled = ControlledByteStream(stream: byteStream)

        do {
            try await processSSEStream(
                bytes: controlled,
                stallTimeout: .seconds(5)
            ) { _, _ in false }
            Issue.record("Expected provider termination missing")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.providerTerminationMissing(diagnostics))) = error else {
                Issue.record("Expected provider termination missing, got \(error)")
                return
            }
            #expect(diagnostics.eventsObserved == 1)
        }
    }
}

struct SSEParserTests {
    @Test
    func aggregatesMultilineDataWithEventMetadata() {
        var parser = SSEEventParser()
        #expect(parser.appendLine("event: message") == nil)
        #expect(parser.appendLine("id: 42") == nil)
        #expect(parser.appendLine("retry: 1000") == nil)
        #expect(parser.appendLine("data: first") == nil)
        #expect(parser.appendLine(": ignored") == nil)
        #expect(parser.appendLine("data: second") == nil)
        let event = parser.appendLine("")

        #expect(event == SSEEvent(event: "message", data: "first\nsecond", id: "42", retry: 1000))
    }

    @Test
    func flushesFinalEventAtEOF() {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data: [DONE]") == nil)
        #expect(parser.finish()?.data == "[DONE]")
    }

    @Test
    func ignoresCommentOnlyEventsAndMalformedRetry() {
        var parser = SSEEventParser()
        #expect(parser.appendLine(": comment") == nil)
        #expect(parser.appendLine("retry: nope") == nil)
        #expect(parser.appendLine("") == nil)

        #expect(parser.appendLine("data: payload") == nil)
        #expect(parser.appendLine("") == SSEEvent(event: nil, data: "payload", id: nil, retry: nil))
    }

    @Test
    func preservesEmptyDataEvents() {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data:") == nil)
        #expect(parser.appendLine("") == SSEEvent(event: nil, data: "", id: nil, retry: nil))
    }
}
