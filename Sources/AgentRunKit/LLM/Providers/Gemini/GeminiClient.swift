import Foundation

/// An LLM client for the Google Gemini API.
public struct GeminiClient: LLMClient, Sendable {
    public let modelIdentifier: String?
    public let maxOutputTokens: Int
    public let contextWindowSize: Int?
    public let providerIdentifier: ProviderIdentifier = .gemini
    let apiKey: String
    let baseURL: URL
    let apiVersion: String
    let additionalHeaders: @Sendable () -> [String: String]
    let session: URLSession
    let retryPolicy: RetryPolicy
    let reasoningConfig: ReasoningConfig?

    public init(
        apiKey: String,
        model: String? = nil,
        maxOutputTokens: Int = 8192,
        contextWindowSize: Int? = nil,
        baseURL: URL = GeminiClient.geminiBaseURL,
        apiVersion: String = "v1beta",
        additionalHeaders: @Sendable @escaping () -> [String: String] = { [:] },
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil
    ) {
        self.apiKey = apiKey
        modelIdentifier = model
        self.maxOutputTokens = maxOutputTokens
        self.contextWindowSize = contextWindowSize
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.additionalHeaders = additionalHeaders
        self.session = session
        self.retryPolicy = retryPolicy
        self.reasoningConfig = reasoningConfig
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
            functionCallingMode: requestContext?.gemini?.functionCallingMode ?? .auto,
            allowedFunctionNames: requestContext?.gemini?.allowedFunctionNames,
            extraFields: requestContext?.extraFields ?? [:]
        )
        let urlRequest = try buildURLRequest(request, stream: false)
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
                        functionCallingMode: requestContext?.gemini?.functionCallingMode ?? .auto,
                        allowedFunctionNames: requestContext?.gemini?.allowedFunctionNames,
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

public extension GeminiClient {
    static let geminiBaseURL = URL(validStaticString: "https://generativelanguage.googleapis.com")
    static let defaultModelIdentifier = "gemini-2.5-flash"
}

extension GeminiClient {
    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat? = nil,
        functionCallingMode: GeminiFunctionCallingMode = .auto,
        allowedFunctionNames: [String]? = nil,
        extraFields: [String: JSONValue] = [:]
    ) throws -> GeminiRequest {
        if tools.isEmpty, functionCallingMode != .auto {
            throw AgentError.llmError(.other(
                "Gemini functionCallingMode requires at least one tool in the request"
            ))
        }
        if allowedFunctionNames != nil, functionCallingMode != .any, functionCallingMode != .validated {
            throw AgentError.llmError(.other(
                "Gemini allowedFunctionNames requires functionCallingMode .any or .validated"
            ))
        }
        if tools.isEmpty, allowedFunctionNames != nil {
            throw AgentError.llmError(.other(
                "Gemini allowedFunctionNames requires at least one tool in the request"
            ))
        }
        let (systemInstruction, contents) = try GeminiMessageMapper.mapMessages(messages)

        let toolDefs: [GeminiTool]? = try tools.isEmpty ? nil : [
            GeminiTool(functionDeclarations: tools.map(GeminiFunctionDeclaration.init))
        ]
        let toolConfig: GeminiToolConfig? = tools.isEmpty ? nil : GeminiToolConfig(
            functionCallingConfig: GeminiFunctionCallingConfig(
                mode: functionCallingMode,
                allowedFunctionNames: allowedFunctionNames
            )
        )

        var responseMimeType: String?
        var responseSchema: GeminiSchema?
        var responseJsonSchema: GeminiSchema?
        if let responseFormat {
            responseMimeType = "application/json"
            let schema = GeminiSchema(responseFormat.schema)
            let capabilities = GeminiCapabilities.resolve(model: resolvedModelIdentifier)
            switch capabilities.preferredSchemaField {
            case .responseJsonSchema:
                responseJsonSchema = schema
            case .responseSchema:
                responseSchema = schema
            }
        }

        let thinkingConfig = try buildThinkingConfig()

        let generationConfig = GeminiGenerationConfig(
            maxOutputTokens: maxOutputTokens,
            thinkingConfig: thinkingConfig,
            responseMimeType: responseMimeType,
            responseSchema: responseSchema,
            responseJsonSchema: responseJsonSchema
        )

        return GeminiRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            tools: toolDefs,
            toolConfig: toolConfig,
            generationConfig: generationConfig,
            extraFields: extraFields
        )
    }

    func buildThinkingConfig() throws -> GeminiThinkingConfig? {
        guard let config = reasoningConfig else { return nil }
        if config.effort == .none, config.budgetTokens == nil { return nil }

        if let budget = config.budgetTokens {
            return GeminiThinkingConfig(
                includeThoughts: true,
                thinkingBudget: budget,
                thinkingLevel: nil
            )
        }

        let capabilities = GeminiCapabilities.resolve(model: resolvedModelIdentifier)
        switch capabilities.thinkingShape {
        case .budget:
            return GeminiThinkingConfig(
                includeThoughts: true,
                thinkingBudget: config.effort.defaultBudgetTokens,
                thinkingLevel: nil
            )
        case .level:
            return GeminiThinkingConfig(
                includeThoughts: true,
                thinkingBudget: nil,
                thinkingLevel: effortToLevel(config.effort)
            )
        case .unknown:
            throw AgentError.llmError(.capabilityMismatch(
                model: resolvedModelIdentifier,
                requirement: "unknown Gemini model family; enumerate in GeminiModelFamily "
                    + "or supply reasoningConfig.budgetTokens explicitly"
            ))
        }
    }

    private func effortToLevel(_ effort: ReasoningConfig.Effort) -> String? {
        switch effort {
        case .xhigh: "HIGH"
        case .high: "HIGH"
        case .medium: "MEDIUM"
        case .low: "LOW"
        case .minimal: "MINIMAL"
        case .none: nil
        }
    }

    func buildURLRequest(_ request: GeminiRequest, stream: Bool) throws -> URLRequest {
        let action = stream ? "streamGenerateContent" : "generateContent"
        let modelPath = "models/\(resolvedModelIdentifier)"
        let path = "\(apiVersion)/\(modelPath):\(action)"
        let url = baseURL.appendingPathComponent(path)

        var queryItems = [URLQueryItem(name: "key", value: apiKey)]
        if stream {
            queryItems.append(URLQueryItem(name: "alt", value: "sse"))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AgentError.llmError(.other("Failed to parse URL components from: \(url)"))
        }
        components.queryItems = queryItems
        guard let finalURL = components.url else {
            throw AgentError.llmError(.other("Failed to construct URL with query items"))
        }

        return try buildJSONPostRequest(url: finalURL, body: request, headers: additionalHeaders())
    }
}

extension GeminiClient {
    private var resolvedModelIdentifier: String {
        modelIdentifier ?? Self.defaultModelIdentifier
    }

    func encodeFunctionCallArgs(_ args: JSONValue?) throws -> String {
        guard let args else { return "{}" }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(args)
        } catch {
            throw AgentError.llmError(.encodingFailed(error))
        }
        guard let str = String(data: encoded, encoding: .utf8) else {
            preconditionFailure("JSONEncoder produced invalid UTF-8")
        }
        return str
    }

    func parseResponse(_ data: Data) throws -> AssistantMessage {
        if let err = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
            throw AgentError.llmError(.other("\(err.error.status): \(err.error.message)"))
        }

        let response: GeminiResponse
        do {
            response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            throw AgentError.llmError(.decodingFailed(error))
        }

        guard let candidate = response.candidates?.first else {
            throw AgentError.llmError(.noChoices)
        }

        var content = ""
        var toolCalls: [ToolCall] = []
        var reasoningText: String?
        var reasoningDetails: [JSONValue] = []
        var syntheticIdCounter = 0

        for part in candidate.content?.parts ?? [] {
            if let functionCall = part.functionCall {
                let callId = functionCall.id ?? {
                    defer { syntheticIdCounter += 1 }
                    return "gemini_call_\(syntheticIdCounter)"
                }()
                let arguments = try encodeFunctionCallArgs(functionCall.args)
                toolCalls.append(ToolCall(id: callId, name: functionCall.name, arguments: arguments))
                if let signature = part.thoughtSignature, !signature.isEmpty {
                    reasoningDetails.append(GeminiReasoningDetail.functionCallSignature(
                        toolCallID: callId,
                        signature: signature
                    ))
                }
            } else if let text = part.text {
                if part.thought == true {
                    reasoningText = reasoningText.map { $0 + "\n" + text } ?? text
                    var detailDict: [String: JSONValue] = [
                        "type": .string("thinking"),
                        "thinking": .string(text)
                    ]
                    if let signature = part.thoughtSignature {
                        detailDict["signature"] = .string(signature)
                    }
                    reasoningDetails.append(.object(detailDict))
                } else {
                    content += text
                }
            }
        }

        return AssistantMessage(
            content: content,
            toolCalls: toolCalls,
            tokenUsage: response.usageMetadata?.tokenUsage,
            reasoning: reasoningText.map { ReasoningContent(content: $0) },
            reasoningDetails: reasoningDetails.isEmpty ? nil : reasoningDetails
        )
    }
}
