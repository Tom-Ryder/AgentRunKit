import Foundation

/// An LLM client for the Anthropic Messages API.
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
    let anthropicReasoning: AnthropicReasoningOptions
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
        anthropicReasoning: AnthropicReasoningOptions = .manual,
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
        self.anthropicReasoning = anthropicReasoning
        self.interleavedThinking = interleavedThinking
        self.cachingEnabled = cachingEnabled
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        try messages.validateForLLMRequest()
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
    static let directInterleavedUnsupportedModels: Set<String> = [
        "claude-opus-4-6"
    ]
    static let vertexInterleavedUnsupportedModels: Set<String> = [
        "claude-opus-4-6",
        "claude-haiku-4-5@20251001"
    ]
    static let adaptiveUnsupportedModels: Set<String> = [
        "claude-haiku-4-5",
        "claude-haiku-4-5-20251001",
        "claude-opus-4-5",
        "claude-opus-4-5-20251101",
        "claude-opus-4-5@20251101",
        "claude-opus-4-1",
        "claude-opus-4-1-20250805",
        "claude-opus-4-1@20250805",
        "claude-opus-4-0",
        "claude-opus-4-20250514",
        "claude-opus-4@20250514",
        "claude-sonnet-4-5",
        "claude-sonnet-4-5-20250929",
        "claude-sonnet-4-5@20250929",
        "claude-sonnet-4-0",
        "claude-sonnet-4-20250514",
        "claude-sonnet-4@20250514",
        "claude-3-7-sonnet",
        "claude-3-7-sonnet-20250219",
        "claude-3-7-sonnet@20250219"
    ]

    public static let anthropicBaseURL = URL(string: "https://api.anthropic.com/v1")!

    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool = false,
        transport: AnthropicTransport = .direct,
        extraFields: [String: JSONValue] = [:]
    ) throws -> AnthropicRequest {
        var (systemBlocks, anthropicMessages) = try AnthropicMessageMapper.mapMessages(messages)
        var toolDefs: [AnthropicToolDefinition]? = tools.isEmpty ? nil : tools.map(AnthropicToolDefinition.init)
        let reasoningPlan = try buildReasoningPlan(transport: transport)

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

        return AnthropicRequest(
            model: modelIdentifier,
            messages: anthropicMessages,
            system: systemBlocks,
            tools: toolDefs,
            maxTokens: maxTokens,
            stream: stream ? true : nil,
            thinking: reasoningPlan.thinking,
            outputConfig: reasoningPlan.outputConfig,
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

    func buildManualThinkingConfig(_ config: ReasoningConfig) throws -> AnthropicThinkingConfig {
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

    func buildReasoningPlan(transport: AnthropicTransport) throws -> AnthropicReasoningPlan {
        guard let reasoningConfig else { return AnthropicReasoningPlan() }
        if reasoningConfig.effort == .none, reasoningConfig.budgetTokens == nil {
            return AnthropicReasoningPlan(thinking: .disabled)
        }

        switch anthropicReasoning.mode {
        case .manual:
            let thinking = try buildManualThinkingConfig(reasoningConfig)
            try validateManualThinking(transport: transport, thinking: thinking)
            return AnthropicReasoningPlan(thinking: thinking)
        case .adaptive:
            try validateAdaptiveReasoning(reasoningConfig)
            return try AnthropicReasoningPlan(
                thinking: .adaptive,
                outputConfig: AnthropicOutputConfig(
                    effort: anthropicOutputEffort(for: reasoningConfig.effort)
                )
            )
        }
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

    private func anthropicOutputEffort(
        for effort: ReasoningConfig.Effort
    ) throws -> AnthropicOutputEffort {
        switch effort {
        case .xhigh: .max
        case .high: .high
        case .medium: .medium
        case .low: .low
        case .minimal:
            throw AgentError.llmError(.other(
                "Anthropic adaptive thinking does not support ReasoningConfig.Effort.minimal. "
                    + "Use .low or manual budget-based thinking instead."
            ))
        case .none:
            throw AgentError.llmError(.other(
                "Anthropic adaptive thinking requires a non-.none reasoning effort."
            ))
        }
    }

    private func validateAdaptiveReasoning(_ config: ReasoningConfig) throws {
        if config.budgetTokens != nil {
            throw AgentError.llmError(.other(
                "Anthropic adaptive thinking does not support explicit budgetTokens. "
                    + "Use anthropicReasoning: .manual with .budget(...) or remove the budget override."
            ))
        }

        guard let modelIdentifier else { return }
        if Self.adaptiveUnsupportedModels.contains(modelIdentifier) {
            throw AgentError.llmError(.other(
                "Anthropic adaptive thinking is only supported on Claude Opus 4.6 and Claude Sonnet 4.6. "
                    + "Model \(modelIdentifier) should use manual thinking instead."
            ))
        }
    }

    private func validateManualThinking(
        transport: AnthropicTransport,
        thinking: AnthropicThinkingConfig
    ) throws {
        guard interleavedThinking, thinking.budgetTokens != nil else { return }

        if let modelIdentifier, Self.directInterleavedUnsupportedModels.contains(modelIdentifier) {
            throw AgentError.llmError(.other(
                "Anthropic manual interleaved thinking is unavailable on \(modelIdentifier). "
                    + "Use anthropicReasoning: .adaptive instead."
            ))
        }

        if transport == .vertex,
           let modelIdentifier,
           Self.vertexInterleavedUnsupportedModels.contains(modelIdentifier) {
            throw AgentError.llmError(.other(
                "Anthropic manual interleaved thinking is unsupported on Vertex AI for model \(modelIdentifier). "
                    + "Disable interleavedThinking or use a model that supports the interleaved-thinking beta."
            ))
        }
    }

    func applyBetaHeaders(
        for request: AnthropicRequest,
        into headers: inout [String: String]
    ) {
        guard interleavedThinking, request.thinking?.budgetTokens != nil else {
            return
        }

        let existing = headers["anthropic-beta"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        let merged = Array(Set(existing).union([Self.interleavedThinkingBeta])).sorted()
        headers["anthropic-beta"] = merged.joined(separator: ",")
    }

    func buildURLRequest(_ request: AnthropicRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("messages")
        var headers = additionalHeaders()
        headers["x-api-key"] = apiKey
        headers["anthropic-version"] = Self.anthropicAPIVersion
        applyBetaHeaders(for: request, into: &headers)
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

        let projection = AnthropicTurnProjection(responseBlocks: response.content)
        return try projection.project(usage: TokenUsage(
            input: response.usage.inputTokens,
            output: response.usage.outputTokens,
            cacheRead: response.usage.cacheReadInputTokens,
            cacheWrite: response.usage.cacheCreationInputTokens
        ))
    }
}

extension AnthropicClient {
    struct AnthropicReasoningPlan {
        let thinking: AnthropicThinkingConfig?
        let outputConfig: AnthropicOutputConfig?

        init(
            thinking: AnthropicThinkingConfig? = nil,
            outputConfig: AnthropicOutputConfig? = nil
        ) {
            self.thinking = thinking
            self.outputConfig = outputConfig
        }
    }

    enum AnthropicTransport {
        case direct
        case vertex
    }
}
