import Foundation

/// An LLM client for OpenAI-compatible Chat Completions APIs.
public struct OpenAIClient: LLMClient, Sendable {
    public let modelIdentifier: String?
    public let maxTokens: Int
    public let contextWindowSize: Int?
    public let profile: OpenAIChatProfile
    public let providerIdentifier: ProviderIdentifier
    let apiKey: String?
    let baseURL: URL
    let chatCompletionPath: String
    let additionalHeaders: @Sendable () -> [String: String]
    let session: URLSession
    let retryPolicy: RetryPolicy
    let reasoningConfig: ReasoningConfig?
    let assistantReplayProfile: OpenAIChatAssistantReplayProfile

    public init(
        apiKey: String? = nil,
        model: String? = nil,
        maxTokens: Int = 16384,
        contextWindowSize: Int? = nil,
        baseURL: URL,
        chatCompletionPath: String = "chat/completions",
        additionalHeaders: @Sendable @escaping () -> [String: String] = { [:] },
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil,
        profile: OpenAIChatProfile = .compatible,
        providerIdentifier: ProviderIdentifier? = nil,
        assistantReplayProfile: OpenAIChatAssistantReplayProfile = .conservative
    ) {
        self.apiKey = apiKey
        modelIdentifier = model
        self.maxTokens = maxTokens
        self.contextWindowSize = contextWindowSize
        self.baseURL = baseURL
        self.chatCompletionPath = chatCompletionPath
        self.additionalHeaders = additionalHeaders
        self.session = session
        self.retryPolicy = retryPolicy
        self.reasoningConfig = reasoningConfig
        self.profile = profile
        self.providerIdentifier = providerIdentifier ?? profile.providerIdentifier
        self.assistantReplayProfile = assistantReplayProfile
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        try messages.validateForLLMRequest()
        let request = try buildRequest(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            extraFields: requestContext?.extraFields ?? [:],
            options: requestContext?.openAIChat
        )
        let urlRequest = try buildURLRequest(request)
        let (data, httpResponse) = try await HTTPRetry.performData(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        requestContext?.onResponse?(httpResponse)
        return try parseResponse(data)
    }

    public func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStreamRequest(
                        messages: messages,
                        tools: tools,
                        options: requestContext?.openAIChat,
                        extraFields: requestContext?.extraFields ?? [:],
                        onResponse: requestContext?.onResponse,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func transcribe(
        audio: Data,
        format: TranscriptionAudioFormat,
        model: String,
        options: TranscriptionOptions = TranscriptionOptions()
    ) async throws -> String {
        guard let apiKey else {
            throw AgentError.llmError(.other("Transcription requires an API key"))
        }
        let request = buildTranscriptionURLRequest(
            audio: audio,
            format: format,
            model: model,
            options: options,
            boundary: UUID().uuidString,
            apiKey: apiKey
        )
        let (data, _) = try await HTTPRetry.performData(
            urlRequest: request, session: session, retryPolicy: retryPolicy
        )
        return try parseTranscriptionResponse(data)
    }

    public func transcribe(
        audioFileURL: URL,
        format: TranscriptionAudioFormat,
        model: String,
        options: TranscriptionOptions = TranscriptionOptions()
    ) async throws -> String {
        guard let apiKey else {
            throw AgentError.llmError(.other("Transcription requires an API key"))
        }
        let boundary = UUID().uuidString
        let (request, bodyURL) = try buildTranscriptionURLRequest(
            audioFileURL: audioFileURL,
            format: format,
            model: model,
            options: options,
            boundary: boundary,
            apiKey: apiKey
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        return try await performUploadWithRetry(urlRequest: request, bodyFileURL: bodyURL) { data, _ in
            try parseTranscriptionResponse(data)
        }
    }
}

extension OpenAIClient {
    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool = false,
        responseFormat: ResponseFormat? = nil,
        extraFields: [String: JSONValue] = [:],
        options: OpenAIChatRequestOptions? = nil
    ) throws -> ChatCompletionRequest {
        let capabilities = OpenAIChatCapabilities.resolve(profile: profile)
        let requestTools = try buildTools(functionTools: tools, options: options, capabilities: capabilities)
        let toolChoice = try resolveToolChoice(
            requestTools: requestTools,
            functionTools: tools,
            options: options,
            capabilities: capabilities
        )
        return try ChatCompletionRequest(
            model: modelIdentifier,
            messages: messages.map { try RequestMessage($0, replayProfile: assistantReplayProfile) },
            tools: requestTools.isEmpty ? nil : requestTools,
            toolChoice: toolChoice,
            parallelToolCalls: options?.parallelToolCalls,
            maxTokens: maxTokens,
            tokenFieldName: capabilities.tokenLimitField.rawValue,
            stream: stream ? true : nil,
            streamOptions: stream ? StreamOptions(includeUsage: true) : nil,
            responseFormat: responseFormat,
            reasoning: reasoningConfig.map(RequestReasoning.init),
            extraFields: extraFields
        )
    }

    private func buildTools(
        functionTools: [ToolDefinition],
        options: OpenAIChatRequestOptions?,
        capabilities: OpenAIChatCapabilities
    ) throws -> [RequestTool] {
        let functionRequestTools = try functionTools.map { try RequestTool($0, profile: capabilities.profile) }
        let customRequestTools = try (options?.customTools ?? []).map {
            try RequestTool(custom: $0, profile: capabilities.profile)
        }
        return functionRequestTools + customRequestTools
    }

    private func resolveToolChoice(
        requestTools: [RequestTool],
        functionTools: [ToolDefinition],
        options: OpenAIChatRequestOptions?,
        capabilities: OpenAIChatCapabilities
    ) throws -> OpenAIChatToolChoice? {
        let functions = Set(functionTools.map(\.name))
        let customs = Set((options?.customTools ?? []).map(\.name))

        guard let toolChoice = options?.toolChoice else {
            return requestTools.isEmpty ? nil : .auto
        }

        switch toolChoice {
        case .required:
            try validateRequiredToolChoice(requestTools)
        case let .function(name):
            try validateRequestedFunctionChoice(name, functions: functions)
        case let .custom(name):
            try validateRequestedCustomChoice(name, customs: customs, capabilities: capabilities)
        case let .allowedTools(_, tools):
            try validateAllowedTools(tools, functions: functions, customs: customs, capabilities: capabilities)
        case .none, .auto:
            break
        }

        return toolChoice
    }

    func buildURLRequest(_ request: ChatCompletionRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(chatCompletionPath)
        var headers: [(String, String)] = []
        if let apiKey {
            headers.append(("Authorization", "Bearer \(apiKey)"))
        }
        headers.append(contentsOf: additionalHeaders().map { ($0.key, $0.value) })
        return try buildJSONPostRequest(url: url, body: request, headers: headers)
    }

    func buildTranscriptionURLRequest(
        audio: Data,
        format: TranscriptionAudioFormat,
        model: String,
        options: TranscriptionOptions,
        boundary: String,
        apiKey: String
    ) -> URLRequest {
        var formData = MultipartFormData(boundary: boundary)
        formData.addField(name: "model", value: model)
        if let language = options.language {
            formData.addField(name: "language", value: language)
        }
        if let prompt = options.prompt {
            formData.addField(name: "prompt", value: prompt)
        }
        if let temperature = options.temperature {
            formData.addField(name: "temperature", value: String(temperature))
        }
        formData.addFile(
            name: "file",
            filename: "audio.\(format.fileExtension)",
            mimeType: format.mimeType,
            data: audio
        )

        let url = baseURL.appendingPathComponent("audio/transcriptions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(formData.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (field, value) in additionalHeaders() {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = formData.encoded()
        return urlRequest
    }

    func buildTranscriptionURLRequest(
        audioFileURL: URL,
        format: TranscriptionAudioFormat,
        model: String,
        options: TranscriptionOptions,
        boundary: String,
        apiKey: String
    ) throws -> (URLRequest, URL) {
        var formData = MultipartFormData(boundary: boundary)
        formData.addField(name: "model", value: model)
        if let language = options.language {
            formData.addField(name: "language", value: language)
        }
        if let prompt = options.prompt {
            formData.addField(name: "prompt", value: prompt)
        }
        if let temperature = options.temperature {
            formData.addField(name: "temperature", value: String(temperature))
        }
        formData.addFile(
            name: "file",
            filename: "audio.\(format.fileExtension)",
            mimeType: format.mimeType,
            fileURL: audioFileURL
        )

        let url = baseURL.appendingPathComponent("audio/transcriptions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(formData.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (field, value) in additionalHeaders() {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        let contentLength: Int
        do {
            contentLength = try formData.contentLength()
        } catch {
            throw AgentError.llmError(.encodingFailed(error))
        }
        urlRequest.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftagent-upload-\(UUID().uuidString)")
        do {
            try formData.write(to: bodyURL)
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw AgentError.llmError(.encodingFailed(error))
        }

        return (urlRequest, bodyURL)
    }

    func parseResponse(_ data: Data) throws -> AssistantMessage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response: ChatCompletionResponse
        do {
            response = try decoder.decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw AgentError.llmError(.decodingFailed(error))
        }

        guard let choice = response.choices.first else {
            throw AgentError.llmError(.noChoices)
        }

        let toolCalls = (choice.message.toolCalls ?? []).map { call in
            ToolCall(id: call.id, name: call.name, arguments: call.arguments, kind: call.kind)
        }

        let tokenUsage = response.usage.map(\.tokenUsage)

        let reasoning = (choice.message.reasoning ?? choice.message.reasoningContent)
            .flatMap { $0.isEmpty ? nil : ReasoningContent(content: $0) }

        let reasoningDetails = try JSONValue.extractReasoningDetails(from: data)

        return AssistantMessage(
            content: choice.message.content ?? "",
            toolCalls: toolCalls,
            tokenUsage: tokenUsage,
            reasoning: reasoning,
            reasoningDetails: reasoningDetails
        )
    }

    func parseTranscriptionResponse(_ data: Data) throws -> String {
        let decoder = JSONDecoder()
        let response: TranscriptionResponse
        do {
            response = try decoder.decode(TranscriptionResponse.self, from: data)
        } catch {
            throw AgentError.llmError(.decodingFailed(error))
        }
        return response.text
    }
}

public extension OpenAIClient {
    static let openAIBaseURL = URL(validStaticString: "https://api.openai.com/v1")
    static let openRouterBaseURL = URL(validStaticString: "https://openrouter.ai/api/v1")
    static let groqBaseURL = URL(validStaticString: "https://api.groq.com/openai/v1")
    static let togetherBaseURL = URL(validStaticString: "https://api.together.xyz/v1")
    static let ollamaBaseURL = URL(validStaticString: "http://localhost:11434/v1")

    static func proxy(
        baseURL: URL,
        maxTokens: Int = 16384,
        contextWindowSize: Int? = nil,
        chatCompletionPath: String = "chat/completions",
        additionalHeaders: @Sendable @escaping () -> [String: String] = { [:] },
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil,
        assistantReplayProfile: OpenAIChatAssistantReplayProfile = .conservative
    ) -> OpenAIClient {
        OpenAIClient(
            apiKey: nil,
            model: nil,
            maxTokens: maxTokens,
            contextWindowSize: contextWindowSize,
            baseURL: baseURL,
            chatCompletionPath: chatCompletionPath,
            additionalHeaders: additionalHeaders,
            session: session,
            retryPolicy: retryPolicy,
            reasoningConfig: reasoningConfig,
            profile: .compatible,
            assistantReplayProfile: assistantReplayProfile
        )
    }

    static func openAI(
        apiKey: String,
        model: String? = nil,
        maxTokens: Int = 16384,
        contextWindowSize: Int? = nil,
        reasoningConfig: ReasoningConfig? = nil
    ) -> OpenAIClient {
        OpenAIClient(
            apiKey: apiKey,
            model: model,
            maxTokens: maxTokens,
            contextWindowSize: contextWindowSize,
            baseURL: openAIBaseURL,
            reasoningConfig: reasoningConfig,
            profile: .firstParty
        )
    }

    static func openRouter(
        apiKey: String,
        model: String? = nil,
        maxTokens: Int = 16384,
        contextWindowSize: Int? = nil,
        reasoningConfig: ReasoningConfig? = nil,
        assistantReplayProfile: OpenAIChatAssistantReplayProfile = .openRouterReasoningDetails
    ) -> OpenAIClient {
        OpenAIClient(
            apiKey: apiKey,
            model: model,
            maxTokens: maxTokens,
            contextWindowSize: contextWindowSize,
            baseURL: openRouterBaseURL,
            reasoningConfig: reasoningConfig,
            profile: .openRouter,
            assistantReplayProfile: assistantReplayProfile
        )
    }
}
