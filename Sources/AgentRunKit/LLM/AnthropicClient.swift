import Foundation

public struct AnthropicClient: LLMClient, Sendable {
    public let modelIdentifier: String?
    public let maxTokens: Int
    public let contextWindowSize: Int?
    let apiKey: String
    let baseURL: URL
    let additionalHeaders: @Sendable () -> [String: String]
    let session: URLSession
    let retryPolicy: RetryPolicy
    let reasoningConfig: ReasoningConfig?
    let interleavedThinking: Bool
    let cachingEnabled: Bool

    public init(
        apiKey: String,
        model: String? = nil,
        maxTokens: Int = 8192,
        contextWindowSize: Int? = nil,
        baseURL: URL = AnthropicClient.anthropicBaseURL,
        additionalHeaders: @Sendable @escaping () -> [String: String] = { [:] },
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil,
        interleavedThinking: Bool = true,
        cachingEnabled: Bool = false
    ) {
        self.apiKey = apiKey
        modelIdentifier = model
        self.maxTokens = maxTokens
        self.contextWindowSize = contextWindowSize
        self.baseURL = baseURL
        self.additionalHeaders = additionalHeaders
        self.session = session
        self.retryPolicy = retryPolicy
        self.reasoningConfig = reasoningConfig
        self.interleavedThinking = interleavedThinking
        self.cachingEnabled = cachingEnabled
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        if responseFormat != nil {
            throw AgentError.llmError(.other("AnthropicClient does not support responseFormat"))
        }
        let request = try buildRequest(
            messages: messages,
            tools: tools,
            extraFields: requestContext?.extraFields ?? [:]
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
}

extension AnthropicClient {
    static let anthropicAPIVersion = "2023-06-01"
    static let interleavedThinkingBeta = "interleaved-thinking-2025-05-14"

    public static let anthropicBaseURL = URL(string: "https://api.anthropic.com/v1")!

    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool = false,
        extraFields: [String: JSONValue] = [:]
    ) throws -> AnthropicRequest {
        var (systemBlocks, anthropicMessages) = try AnthropicMessageMapper.mapMessages(messages)
        var toolDefs: [AnthropicToolDefinition]? = tools.isEmpty ? nil : tools.map(AnthropicToolDefinition.init)

        if cachingEnabled {
            if var last = systemBlocks?.popLast() {
                last.cacheControl = CacheControl()
                systemBlocks?.append(last)
            }
            if var last = toolDefs?.popLast() {
                last.cacheControl = CacheControl()
                toolDefs?.append(last)
            }
            markSecondToLastUserMessage(&anthropicMessages)
        }

        return try AnthropicRequest(
            model: modelIdentifier,
            messages: anthropicMessages,
            system: systemBlocks,
            tools: toolDefs,
            maxTokens: maxTokens,
            stream: stream ? true : nil,
            thinking: buildThinkingConfig(),
            extraFields: extraFields
        )
    }

    private func markSecondToLastUserMessage(_ messages: inout [AnthropicMessage]) {
        var textUserIndices: [Int] = []
        for (index, msg) in messages.enumerated() where msg.role == .user {
            if case .text = msg.content {
                textUserIndices.append(index)
            }
        }
        guard textUserIndices.count >= 2 else { return }
        let targetIndex = textUserIndices[textUserIndices.count - 2]
        if case let .text(string) = messages[targetIndex].content {
            messages[targetIndex].content = .textWithCacheControl(string)
        }
    }

    func buildThinkingConfig() throws -> AnthropicThinkingConfig? {
        guard let config = reasoningConfig else { return nil }
        if config.effort == .none, config.budgetTokens == nil { return .disabled }

        let rawBudget = config.budgetTokens ?? effortToBudget(config.effort)
        let floored = max(rawBudget, 1024)
        let capped = interleavedThinking ? floored : min(floored, maxTokens - 1)

        guard capped >= 1024 else {
            throw AgentError.llmError(.other(
                "maxTokens (\(maxTokens)) is too small for thinking; "
                    + "budget \(capped) is below Anthropic's 1024-token minimum"
            ))
        }

        return .enabled(budgetTokens: capped)
    }

    private func effortToBudget(_ effort: ReasoningConfig.Effort) -> Int {
        switch effort {
        case .xhigh: 32768
        case .high: 16384
        case .medium: 8192
        case .low: 4096
        case .minimal: 1024
        case .none: 0
        }
    }

    func buildURLRequest(_ request: AnthropicRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("messages")
        var headers = additionalHeaders()
        headers["x-api-key"] = apiKey
        headers["anthropic-version"] = Self.anthropicAPIVersion
        if interleavedThinking, reasoningConfig != nil {
            headers["anthropic-beta"] = Self.interleavedThinkingBeta
        }
        return try buildJSONPostRequest(url: url, body: request, headers: headers)
    }

    func parseResponse(_ data: Data) throws -> AssistantMessage {
        let response: AnthropicResponse
        do {
            response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch let decodingError {
            if let err = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data),
               err.type == "error" {
                throw AgentError.llmError(.other("\(err.error.type): \(err.error.message)"))
            }
            throw AgentError.llmError(.decodingFailed(decodingError))
        }

        var content = ""
        var toolCalls: [ToolCall] = []
        var reasoningText: String?
        var reasoningDetails: [JSONValue] = []

        for block in response.content {
            switch block {
            case let .text(text):
                content += text
            case let .thinking(thinking, signature):
                reasoningText = reasoningText.map { $0 + "\n" + thinking } ?? thinking
                reasoningDetails.append(.object([
                    "type": .string("thinking"),
                    "thinking": .string(thinking),
                    "signature": .string(signature)
                ]))
            case let .toolUse(id, name, input):
                let encoded: Data
                do {
                    encoded = try JSONEncoder().encode(input)
                } catch {
                    throw AgentError.llmError(.encodingFailed(error))
                }
                guard let arguments = String(data: encoded, encoding: .utf8) else {
                    preconditionFailure("JSONEncoder produced invalid UTF-8")
                }
                toolCalls.append(ToolCall(
                    id: id, name: name, arguments: arguments
                ))
            }
        }

        return AssistantMessage(
            content: content,
            toolCalls: toolCalls,
            tokenUsage: TokenUsage(
                input: response.usage.inputTokens,
                output: response.usage.outputTokens,
                cacheRead: response.usage.cacheReadInputTokens,
                cacheWrite: response.usage.cacheCreationInputTokens
            ),
            reasoning: reasoningText.map { ReasoningContent(content: $0) },
            reasoningDetails: reasoningDetails.isEmpty ? nil : reasoningDetails
        )
    }
}
