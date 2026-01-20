import Foundation

public struct OpenAIClient: LLMClient, Sendable {
    public let modelIdentifier: String
    public let maxTokens: Int
    let apiKey: String
    let baseURL: URL
    let chatCompletionPath: String
    let additionalHeaders: [String: String]
    let session: URLSession
    let retryPolicy: RetryPolicy
    let reasoningConfig: ReasoningConfig?

    public init(
        apiKey: String,
        model: String,
        maxTokens: Int = 16384,
        baseURL: URL,
        chatCompletionPath: String = "chat/completions",
        additionalHeaders: [String: String] = [:],
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil
    ) {
        self.apiKey = apiKey
        modelIdentifier = model
        self.maxTokens = maxTokens
        self.baseURL = baseURL
        self.chatCompletionPath = chatCompletionPath
        self.additionalHeaders = additionalHeaders
        self.session = session
        self.retryPolicy = retryPolicy
        self.reasoningConfig = reasoningConfig
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?
    ) async throws -> AssistantMessage {
        try await generate(messages: messages, tools: tools, responseFormat: responseFormat, context: nil)
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        context: RequestContext?
    ) async throws -> AssistantMessage {
        let request = buildRequest(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            extraFields: context?.extraFields ?? [:]
        )
        let urlRequest = try buildURLRequest(request)
        return try await performWithRetry(urlRequest: urlRequest, onResponse: context?.onResponse) { data, _ in
            try parseResponse(data)
        }
    }

    public func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        stream(messages: messages, tools: tools, context: nil)
    }

    public func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        context: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStreamRequest(
                        messages: messages,
                        tools: tools,
                        extraFields: context?.extraFields ?? [:],
                        onResponse: context?.onResponse,
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
        let request = buildTranscriptionURLRequest(
            audio: audio,
            format: format,
            model: model,
            options: options,
            boundary: UUID().uuidString
        )
        return try await performWithRetry(urlRequest: request) { data, _ in
            try parseTranscriptionResponse(data)
        }
    }

    public func transcribe(
        audioFileURL: URL,
        format: TranscriptionAudioFormat,
        model: String,
        options: TranscriptionOptions = TranscriptionOptions()
    ) async throws -> String {
        let boundary = UUID().uuidString
        let (request, bodyURL) = try buildTranscriptionURLRequest(
            audioFileURL: audioFileURL,
            format: format,
            model: model,
            options: options,
            boundary: boundary
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
        extraFields: [String: JSONValue] = [:]
    ) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: modelIdentifier,
            messages: messages.map(RequestMessage.init),
            tools: tools.isEmpty ? nil : tools.map(RequestTool.init),
            toolChoice: tools.isEmpty ? nil : "auto",
            maxTokens: maxTokens,
            stream: stream ? true : nil,
            streamOptions: stream ? StreamOptions(includeUsage: true) : nil,
            responseFormat: responseFormat,
            reasoning: reasoningConfig.map(RequestReasoning.init),
            extraFields: extraFields
        )
    }

    func buildURLRequest(_ request: ChatCompletionRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(chatCompletionPath)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (field, value) in additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        let encoder = JSONEncoder()
        do {
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw AgentError.llmError(.encodingFailed(error))
        }
        return urlRequest
    }

    func buildTranscriptionURLRequest(
        audio: Data,
        format: TranscriptionAudioFormat,
        model: String,
        options: TranscriptionOptions,
        boundary: String
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
        for (field, value) in additionalHeaders {
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
        boundary: String
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
        for (field, value) in additionalHeaders {
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
            ToolCall(id: call.id, name: call.function.name, arguments: call.function.arguments)
        }

        let tokenUsage = response.usage.map { usage in
            let reasoningTokens = usage.completionTokensDetails?.reasoningTokens ?? 0
            let outputMinusReasoning = max(0, usage.completionTokens - reasoningTokens)
            return TokenUsage(
                input: usage.promptTokens,
                output: outputMinusReasoning,
                reasoning: reasoningTokens
            )
        }

        let reasoning = (choice.message.reasoning ?? choice.message.reasoningContent)
            .flatMap { $0.isEmpty ? nil : ReasoningContent(content: $0) }

        return AssistantMessage(
            content: choice.message.content ?? "",
            toolCalls: toolCalls,
            tokenUsage: tokenUsage,
            reasoning: reasoning
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
    static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!
    static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    static let groqBaseURL = URL(string: "https://api.groq.com/openai/v1")!
    static let togetherBaseURL = URL(string: "https://api.together.xyz/v1")!
    static let ollamaBaseURL = URL(string: "http://localhost:11434/v1")!
}
