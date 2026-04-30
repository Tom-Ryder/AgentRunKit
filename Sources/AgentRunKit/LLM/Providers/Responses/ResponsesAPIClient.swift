import Foundation

/// An LLM client for the OpenAI Responses API.
public actor ResponsesAPIClient: LLMClient, HistoryRewriteAwareClient {
    public nonisolated let modelIdentifier: String?
    public nonisolated let maxOutputTokens: Int?
    public nonisolated let contextWindowSize: Int?
    public nonisolated let providerIdentifier: ProviderIdentifier = .openAIResponses
    nonisolated let apiKey: String?
    nonisolated let baseURL: URL
    nonisolated let responsesPath: String
    nonisolated let additionalHeaders: @Sendable () -> [String: String]
    nonisolated let session: URLSession
    nonisolated let retryPolicy: RetryPolicy
    nonisolated let reasoningConfig: ReasoningConfig?
    nonisolated let store: Bool

    var lastResponseId: String?
    var lastMessageCount: Int = 0
    var lastPrefixSignature: Data = .init()
    var pendingInputMessages: [ChatMessage]?

    public init(
        apiKey: String? = nil,
        model: String? = nil,
        maxOutputTokens: Int? = nil,
        contextWindowSize: Int? = nil,
        baseURL: URL,
        responsesPath: String = "responses",
        additionalHeaders: @Sendable @escaping () -> [String: String] = { [:] },
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil,
        store: Bool = true
    ) {
        self.apiKey = apiKey
        modelIdentifier = model
        self.maxOutputTokens = maxOutputTokens
        self.contextWindowSize = contextWindowSize
        self.baseURL = baseURL
        self.responsesPath = responsesPath
        self.additionalHeaders = additionalHeaders
        self.session = session
        self.retryPolicy = retryPolicy
        self.reasoningConfig = reasoningConfig
        self.store = store
    }
}

extension ResponsesAPIClient {
    struct ResponsesTurnProjection {
        let content: String
        let toolCalls: [ToolCall]
        let tokenUsage: TokenUsage?
        let reasoning: ReasoningContent?
        let reasoningDetails: [JSONValue]?
        let continuity: AssistantContinuity?
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        try await generate(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            requestContext: requestContext,
            requestMode: .auto
        )
    }

    func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?,
        requestMode: RunRequestMode
    ) async throws -> AssistantMessage {
        try messages.validateForLLMRequest()
        if shouldResetConversationBeforeRequest(messages: messages, requestMode: requestMode) {
            resetConversation()
        }
        let request = try buildRequest(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            extraFields: requestContext?.extraFields ?? [:],
            requestMode: requestMode,
            options: requestContext?.responses
        )
        let urlRequest = try buildURLRequest(request)
        let (data, httpResponse) = try await HTTPRetry.performData(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        requestContext?.onResponse?(httpResponse)
        let response = try decodeResponse(data)
        try checkResponseError(response)
        let message = projectResponse(response).assistantMessage
        lastResponseId = response.id
        lastMessageCount = messages.count + 1
        lastPrefixSignature = prefixSignature(messages + [.assistant(message)])
        return message
    }

    public nonisolated func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in self.streamForRun(
                        messages: messages,
                        tools: tools,
                        requestContext: requestContext,
                        requestMode: .auto
                    ) {
                        guard case let .delta(delta) = element else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func streamForRun(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?,
        requestMode: RunRequestMode
    ) -> AsyncThrowingStream<RunStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStreamRequest(
                        messages: messages,
                        tools: tools,
                        extraFields: requestContext?.extraFields ?? [:],
                        onResponse: requestContext?.onResponse,
                        requestMode: requestMode,
                        options: requestContext?.responses,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func resetConversation() {
        lastResponseId = nil
        lastMessageCount = 0
        lastPrefixSignature = Data()
        pendingInputMessages = nil
    }

    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool = false,
        responseFormat: ResponseFormat? = nil,
        extraFields: [String: JSONValue] = [:],
        requestMode: RunRequestMode = .auto,
        options: ResponsesRequestOptions? = nil
    ) throws -> ResponsesRequest {
        let buildOptions = ResponsesRequestBuildOptions(
            tools: tools,
            stream: stream,
            responseFormat: responseFormat,
            extraFields: extraFields,
            requestOptions: options
        )

        if requestMode == .forceFullRequest {
            return try buildFullRequest(messages: messages, options: buildOptions)
        }

        guard store else {
            return try buildFullRequest(messages: messages, options: buildOptions)
        }

        if let previousId = lastResponseId, messages.count >= lastMessageCount,
           lastMessageCount > 0,
           prefixSignature(messages.prefix(lastMessageCount)) == lastPrefixSignature {
            return try buildDeltaRequest(
                messages: messages,
                previousResponseId: previousId,
                suffixStart: lastMessageCount,
                options: buildOptions
            )
        }

        if let anchor = try responsesContinuationAnchor(in: messages) {
            return try buildDeltaRequest(
                messages: messages,
                previousResponseId: anchor.responseId,
                suffixStart: anchor.suffixStart,
                options: buildOptions
            )
        }

        return try buildFullRequest(messages: messages, options: buildOptions)
    }

    nonisolated func responsesContinuationAnchor(in messages: [ChatMessage]) throws
        -> (responseId: String, suffixStart: Int)? {
        guard !messages.isEmpty else { return nil }
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            guard case let .assistant(message) = messages[index],
                  let continuity = message.continuity,
                  continuity.substrate == .responses
            else {
                continue
            }
            let replayState = try ResponsesReplayState(continuity: continuity)
            guard let responseId = replayState.responseId else { continue }
            return (responseId, index + 1)
        }
        return nil
    }

    func shouldResetConversationBeforeRequest(messages: [ChatMessage], requestMode: RunRequestMode) -> Bool {
        requestMode == .forceFullRequest || (store && messages.count < lastMessageCount)
    }

    func decodeResponse(_ data: Data) throws -> ResponsesAPIResponse {
        do {
            return try JSONDecoder().decode(ResponsesAPIResponse.self, from: data)
        } catch {
            throw AgentError.llmError(.decodingFailed(error))
        }
    }

    func checkResponseError(_ response: ResponsesAPIResponse) throws {
        if let error = response.error {
            throw AgentError.llmError(
                .other("\(error.code): \(error.message)")
            )
        }
        if let status = response.status, status != "completed" {
            throw AgentError.llmError(.other("Unexpected Responses status: \(status)"))
        }
    }

    func parseResponse(_ response: ResponsesAPIResponse) -> AssistantMessage {
        projectResponse(response).assistantMessage
    }

    func projectResponse(_ response: ResponsesAPIResponse) -> ResponsesTurnProjection {
        var content = ""
        var toolCalls: [ToolCall] = []
        var reasoningDetails: [JSONValue] = []
        var reasoningSummary: String?

        for item in response.output {
            switch item {
            case let .message(msg):
                for part in msg.content where part.type == "output_text" {
                    if let text = part.text {
                        content += text
                    }
                }
            case let .functionCall(call):
                toolCalls.append(ToolCall(
                    id: call.callId, name: call.name, arguments: call.arguments
                ))
            case let .opaque(opaque) where opaque.type == "custom_tool_call":
                guard case let .object(fields) = opaque.raw,
                      case let .string(callId) = fields["call_id"],
                      case let .string(name) = fields["name"]
                else { break }
                let input = if case let .string(text) = fields["input"] { text } else { "" }
                toolCalls.append(ToolCall(id: callId, name: name, arguments: input, kind: .custom))
            case let .reasoning(reasoning):
                reasoningDetails.append(reasoning.raw)
                let value = reasoning.raw
                if case let .object(dict) = value,
                   case let .array(summaryItems) = dict["summary"] {
                    for item in summaryItems {
                        if case let .object(summaryDict) = item,
                           case let .string(sType) = summaryDict["type"],
                           sType == "summary_text",
                           case let .string(text) = summaryDict["text"] {
                            reasoningSummary = reasoningSummary
                                .map { $0 + "\n" + text } ?? text
                        }
                    }
                }
            case .opaque:
                break
            }
        }

        let reasoningTokens = response.usage?.outputTokensDetails?.reasoningTokens ?? 0
        let tokenUsage = response.usage.map { usage in
            TokenUsage(
                input: usage.inputTokens,
                output: max(0, usage.outputTokens - reasoningTokens),
                reasoning: reasoningTokens
            )
        }

        let replayState = ResponsesReplayState(response: response)
        let continuityReplayState = store
            ? replayState
            : ResponsesReplayState(output: replayState.output, responseId: nil)
        return ResponsesTurnProjection(
            content: content,
            toolCalls: toolCalls,
            tokenUsage: tokenUsage,
            reasoning: reasoningSummary.map { ReasoningContent(content: $0) },
            reasoningDetails: reasoningDetails.isEmpty ? nil : reasoningDetails,
            continuity: continuityReplayState.output.isEmpty ? nil : continuityReplayState.continuity
        )
    }
}

extension ResponsesAPIClient.ResponsesTurnProjection {
    var assistantMessage: AssistantMessage {
        AssistantMessage(
            content: content,
            toolCalls: toolCalls,
            tokenUsage: tokenUsage,
            reasoning: reasoning,
            reasoningDetails: reasoningDetails,
            continuity: continuity
        )
    }
}

extension ResponsesAPIClient {
    func buildURLRequest(_ request: ResponsesRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(responsesPath)
        var headers: [(String, String)] = []
        if let apiKey {
            headers.append(("Authorization", "Bearer \(apiKey)"))
        }
        headers.append(contentsOf: additionalHeaders().map { ($0.key, $0.value) })
        return try buildJSONPostRequest(url: url, body: request, headers: headers)
    }
}

public extension ResponsesAPIClient {
    nonisolated static let openAIBaseURL =
        URL(validStaticString: "https://api.openai.com/v1")
}
