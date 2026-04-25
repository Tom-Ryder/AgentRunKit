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
    let cacheControlTTL: CacheControlTTL?

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
        cachingEnabled: Bool = false,
        cacheControlTTL: CacheControlTTL? = nil
    ) throws {
        try self.init(
            apiKey: apiKey,
            model: model,
            maxTokens: maxTokens,
            contextWindowSize: contextWindowSize,
            baseURL: baseURL,
            additionalHeaders: additionalHeaders,
            session: session,
            retryPolicy: retryPolicy,
            reasoningConfig: reasoningConfig,
            anthropicReasoning: anthropicReasoning,
            interleavedThinking: interleavedThinking,
            cachingEnabled: cachingEnabled,
            cacheControlTTL: cacheControlTTL,
            capabilityTransport: .direct
        )
    }

    init(
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
        cachingEnabled: Bool = false,
        cacheControlTTL: CacheControlTTL? = nil,
        capabilityTransport: AnthropicCapabilities.Transport
    ) throws {
        try Self.validateReasoningAtConstruction(
            model: model,
            reasoningConfig: reasoningConfig,
            anthropicReasoning: anthropicReasoning,
            transport: capabilityTransport
        )
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
        self.cacheControlTTL = cacheControlTTL
    }

    private static func validateReasoningAtConstruction(
        model: String?,
        reasoningConfig: ReasoningConfig?,
        anthropicReasoning: AnthropicReasoningOptions,
        transport: AnthropicCapabilities.Transport
    ) throws {
        guard let reasoningConfig else { return }
        let hasActiveReasoning = reasoningConfig.effort != .none || reasoningConfig.budgetTokens != nil
        guard hasActiveReasoning else { return }

        let capabilities = AnthropicCapabilities.resolve(model: model, transport: transport)

        if capabilities.reasoningPolicy == .unknown {
            throw AgentError.llmError(.capabilityMismatch(
                model: model ?? "<unspecified>",
                requirement: "unknown Anthropic model family; enumerate in AnthropicModelFamily "
                    + "or omit reasoningConfig"
            ))
        }

        if capabilities.reasoningPolicy == .adaptiveRequired, anthropicReasoning.mode == .manual {
            throw AgentError.llmError(.capabilityMismatch(
                model: model ?? "<unspecified>",
                requirement: "requires adaptive thinking; set anthropicReasoning: .adaptive at construction"
            ))
        }

        if capabilities.reasoningPolicy == .manualOnly, anthropicReasoning.mode == .adaptive {
            throw AgentError.llmError(.capabilityMismatch(
                model: model ?? "<unspecified>",
                requirement: "does not support adaptive thinking; set anthropicReasoning: .manual at construction"
            ))
        }
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
            toolChoice: requestContext?.anthropic?.toolChoice,
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
                        toolChoice: requestContext?.anthropic?.toolChoice,
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

extension AnthropicClient: ContentOnlyTerminatingClient {}

extension AnthropicClient {
    static let anthropicAPIVersion = "2023-06-01"
    static let interleavedThinkingBeta = "interleaved-thinking-2025-05-14"

    public static let anthropicBaseURL = URL(string: "https://api.anthropic.com/v1")!

    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool = false,
        transport: AnthropicCapabilities.Transport = .direct,
        responseFormat: ResponseFormat? = nil,
        toolChoice: AnthropicToolChoice? = nil,
        extraFields: [String: JSONValue] = [:]
    ) throws -> AnthropicRequest {
        var (systemBlocks, anthropicMessages) = try AnthropicMessageMapper.mapMessages(messages)
        var toolDefs: [AnthropicToolDefinition]? = try tools.isEmpty ? nil : tools.map(AnthropicToolDefinition.init)
        let reasoningPlan = try buildReasoningPlan(transport: transport)
        let hasActiveThinking = switch reasoningPlan.thinking {
        case .enabled, .adaptive:
            true
        case .disabled, nil:
            false
        }
        try validateToolChoice(
            toolChoice,
            transport: transport,
            hasActiveThinking: hasActiveThinking
        )
        let outputConfig = mergeOutputConfig(
            reasoning: reasoningPlan.outputConfig,
            responseFormat: responseFormat
        )

        if cachingEnabled {
            if var last = systemBlocks?.popLast() {
                last.cacheControl = CacheControl(ttl: cacheControlTTL)
                systemBlocks?.append(last)
            }
            if var last = toolDefs?.popLast() {
                last.cacheControl = CacheControl(ttl: cacheControlTTL)
                toolDefs?.append(last)
            }
            markSecondToLastUserMessage(&anthropicMessages)
        }

        return AnthropicRequest(
            model: modelIdentifier,
            messages: anthropicMessages,
            system: systemBlocks,
            tools: toolDefs,
            toolChoice: toolChoice,
            maxTokens: maxTokens,
            stream: stream ? true : nil,
            thinking: reasoningPlan.thinking,
            outputConfig: outputConfig,
            extraFields: extraFields
        )
    }

    private func mergeOutputConfig(
        reasoning: AnthropicOutputConfig?,
        responseFormat: ResponseFormat?
    ) -> AnthropicOutputConfig? {
        let format = responseFormat.map {
            AnthropicJSONOutputFormat(schema: $0.schema)
        }
        if reasoning == nil, format == nil { return nil }
        return AnthropicOutputConfig(effort: reasoning?.effort, format: format)
    }

    private func markSecondToLastUserMessage(_ messages: inout [AnthropicMessage]) {
        let userIndices = messages.indices.filter {
            messages[$0].role == .user && !messages[$0].content.isToolResultOnly
        }
        guard userIndices.count >= 2 else { return }

        for index in userIndices.dropLast().reversed() {
            guard let updated = messages[index].content.applyingCacheControl(ttl: cacheControlTTL) else {
                continue
            }
            messages[index].content = updated
            return
        }
    }

    func buildManualThinkingConfig(_ config: ReasoningConfig) throws -> AnthropicThinkingConfig {
        if config.effort == .none, config.budgetTokens == nil { return .disabled }

        let rawBudget = config.budgetTokens ?? config.effort.defaultBudgetTokens
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

    func buildReasoningPlan(transport: AnthropicCapabilities.Transport) throws -> AnthropicReasoningPlan {
        guard let reasoningConfig else { return AnthropicReasoningPlan() }
        if reasoningConfig.effort == .none, reasoningConfig.budgetTokens == nil {
            let capabilities = AnthropicCapabilities.resolve(
                model: modelIdentifier,
                transport: transport
            )
            guard capabilities.supportsThinkingDisabled else {
                throw AgentError.llmError(.capabilityMismatch(
                    model: modelIdentifier ?? "<unspecified>",
                    requirement: "does not support thinking.type = \"disabled\""
                ))
            }
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
                thinking: .adaptive(display: anthropicReasoning.display),
                outputConfig: AnthropicOutputConfig(
                    effort: anthropicOutputEffort(for: reasoningConfig.effort)
                )
            )
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
    }

    private func validateManualThinking(
        transport: AnthropicCapabilities.Transport,
        thinking: AnthropicThinkingConfig
    ) throws {
        guard interleavedThinking, thinking.budgetTokens != nil else { return }

        let capabilities = AnthropicCapabilities.resolve(
            model: modelIdentifier,
            transport: transport
        )
        guard case .unsupported = capabilities.interleavedBetaPolicy else { return }

        let requirement = "does not support manual interleaved thinking on "
            + (transport == .vertex ? "Vertex" : "direct")
            + "; set anthropicReasoning: .adaptive or disable interleavedThinking"
        throw AgentError.llmError(.capabilityMismatch(
            model: modelIdentifier ?? "<unspecified>",
            requirement: requirement
        ))
    }

    private func validateToolChoice(
        _ toolChoice: AnthropicToolChoice?,
        transport: AnthropicCapabilities.Transport,
        hasActiveThinking: Bool
    ) throws {
        guard let toolChoice else { return }
        let capabilities = AnthropicCapabilities.resolve(
            model: modelIdentifier,
            transport: transport
        )

        switch toolChoice {
        case .any, .tool:
            guard capabilities.supportsForcedToolChoice else {
                throw AgentError.llmError(.capabilityMismatch(
                    model: modelIdentifier ?? "<unspecified>",
                    requirement: "does not support forced tool choice"
                ))
            }
            if hasActiveThinking {
                throw AgentError.llmError(.capabilityMismatch(
                    model: modelIdentifier ?? "<unspecified>",
                    requirement: "forced tool choice is incompatible with active thinking; use .auto or .none"
                ))
            }
        case .none, .auto:
            break
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
}
