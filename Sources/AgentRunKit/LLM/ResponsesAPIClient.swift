import Foundation

/// An LLM client for the OpenAI Responses API.
public actor ResponsesAPIClient: LLMClient, HistoryRewriteAwareClient {
    public nonisolated let modelIdentifier: String?
    public nonisolated let maxOutputTokens: Int?
    public nonisolated let contextWindowSize: Int?
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
            requestMode: requestMode
        )
        let urlRequest = try buildURLRequest(request)
        let (data, httpResponse) = try await HTTPRetry.performData(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        requestContext?.onResponse?(httpResponse)
        let response = try decodeResponse(data)
        try checkResponseError(response)
        let message = parseResponse(response)
        lastResponseId = response.id
        lastMessageCount = messages.count + 1
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
    }

    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool = false,
        responseFormat: ResponseFormat? = nil,
        extraFields: [String: JSONValue] = [:],
        requestMode: RunRequestMode = .auto
    ) throws -> ResponsesRequest {
        if requestMode == .forceFullRequest {
            return try buildFullRequest(
                messages: messages,
                tools: tools,
                stream: stream,
                responseFormat: responseFormat,
                extraFields: extraFields
            )
        }

        if store, let previousId = lastResponseId, messages.count >= lastMessageCount {
            return try buildDeltaRequest(
                messages: messages,
                tools: tools,
                stream: stream,
                responseFormat: responseFormat,
                previousResponseId: previousId,
                extraFields: extraFields
            )
        }

        return try buildFullRequest(
            messages: messages,
            tools: tools,
            stream: stream,
            responseFormat: responseFormat,
            extraFields: extraFields
        )
    }

    func shouldResetConversationBeforeRequest(
        messages: [ChatMessage],
        requestMode: RunRequestMode
    ) -> Bool {
        requestMode == .forceFullRequest || (store && messages.count < lastMessageCount)
    }

    func mapMessages(
        _ messages: [ChatMessage]
    ) throws -> (instructions: String?, input: [ResponsesInputItem]) {
        var systemParts: [String] = []
        var items: [ResponsesInputItem] = []

        for message in messages {
            switch message {
            case let .system(text):
                systemParts.append(text)

            case let .user(text):
                items.append(.userMessage(role: "user", content: text))

            case let .userMultimodal(parts):
                var textParts: [String] = []
                for part in parts {
                    guard case let .text(text) = part else {
                        throw AgentError.llmError(.other(
                            "Responses API does not support non-text content parts"
                        ))
                    }
                    textParts.append(text)
                }
                items.append(.userMessage(role: "user", content: textParts.joined(separator: "\n")))

            case let .assistant(msg):
                if let details = msg.reasoningDetails {
                    for detail in details {
                        items.append(.reasoning(detail))
                    }
                }
                if !msg.content.isEmpty {
                    items.append(.assistantMessage(ResponsesAssistantItem(
                        content: [ResponsesOutputTextItem(text: msg.content)]
                    )))
                }
                for call in msg.toolCalls {
                    items.append(.functionCall(ResponsesFunctionCallItem(
                        callId: call.id,
                        name: call.name,
                        arguments: call.arguments
                    )))
                }

            case let .tool(id, _, content):
                items.append(.functionCallOutput(ResponsesFunctionCallOutputItem(
                    callId: id,
                    output: content
                )))
            }
        }

        let instructions = systemParts.isEmpty
            ? nil : systemParts.joined(separator: "\n")
        return (instructions, items)
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
    }

    func parseResponse(_ response: ResponsesAPIResponse) -> AssistantMessage {
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
            case let .reasoning(value):
                reasoningDetails.append(value)
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
            }
        }

        let reasoningTokens =
            response.usage?.outputTokensDetails?.reasoningTokens ?? 0
        let tokenUsage = response.usage.map { usage in
            TokenUsage(
                input: usage.inputTokens,
                output: max(0, usage.outputTokens - reasoningTokens),
                reasoning: reasoningTokens
            )
        }

        return AssistantMessage(
            content: content,
            toolCalls: toolCalls,
            tokenUsage: tokenUsage,
            reasoning: reasoningSummary.map { ReasoningContent(content: $0) },
            reasoningDetails: reasoningDetails.isEmpty ? nil : reasoningDetails
        )
    }

    func buildURLRequest(_ request: ResponsesRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(responsesPath)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in additionalHeaders() {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw AgentError.llmError(.encodingFailed(error))
        }
        return urlRequest
    }
}

extension ResponsesAPIClient {
    private func buildFullRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool,
        responseFormat: ResponseFormat?,
        extraFields: [String: JSONValue]
    ) throws -> ResponsesRequest {
        let (instructions, inputItems) = try mapMessages(messages)
        let include: [String]? = store ? nil : ["reasoning.encrypted_content"]
        return ResponsesRequest(
            model: modelIdentifier,
            instructions: instructions,
            input: inputItems,
            tools: tools.isEmpty ? nil : tools.map(ResponsesToolDefinition.init),
            stream: stream ? true : nil,
            maxOutputTokens: maxOutputTokens,
            text: responseFormat.map {
                ResponsesTextConfig(format: ResponsesFormatConfig(
                    name: $0.schemaName, schema: $0.schema
                ))
            },
            store: store,
            reasoning: reasoningConfig.map(ResponsesReasoningConfig.init),
            include: include,
            previousResponseId: nil,
            extraFields: extraFields
        )
    }

    private func buildDeltaRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool,
        responseFormat: ResponseFormat?,
        previousResponseId: String,
        extraFields: [String: JSONValue]
    ) throws -> ResponsesRequest {
        let newMessages = Array(messages[lastMessageCount...])
        let filtered: [ChatMessage] =
            if let first = newMessages.first, case .assistant = first {
                Array(newMessages.dropFirst())
            } else {
                newMessages
            }

        let (_, inputItems) = try mapMessages(filtered)
        let include: [String]? = store ? nil : ["reasoning.encrypted_content"]
        return ResponsesRequest(
            model: modelIdentifier,
            instructions: nil,
            input: inputItems,
            tools: tools.isEmpty ? nil : tools.map(ResponsesToolDefinition.init),
            stream: stream ? true : nil,
            maxOutputTokens: maxOutputTokens,
            text: responseFormat.map {
                ResponsesTextConfig(format: ResponsesFormatConfig(
                    name: $0.schemaName, schema: $0.schema
                ))
            },
            store: store,
            reasoning: reasoningConfig.map(ResponsesReasoningConfig.init),
            include: include,
            previousResponseId: previousResponseId,
            extraFields: extraFields
        )
    }
}

public extension ResponsesAPIClient {
    nonisolated static let openAIBaseURL =
        URL(string: "https://api.openai.com/v1")!
    nonisolated static let chatGPTBaseURL =
        URL(string: "https://chatgpt.com/backend-api/codex")!
}
