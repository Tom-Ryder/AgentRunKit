import Foundation

extension ResponsesAPIClient {
    private static let sseDecoder = JSONDecoder()

    func performStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        requestMode: RunRequestMode = .auto,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        try messages.validateForLLMRequest()
        if shouldResetConversationBeforeRequest(messages: messages, requestMode: requestMode) {
            resetConversation()
        }
        let request = try buildRequest(
            messages: messages, tools: tools,
            stream: true, extraFields: extraFields,
            requestMode: requestMode
        )
        let urlRequest = try buildURLRequest(request)
        let (bytes, httpResponse) = try await HTTPRetry.performStream(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        onResponse?(httpResponse)
        let messagesCount = messages.count
        try await processSSEStream(
            bytes: bytes,
            stallTimeout: retryPolicy.streamStallTimeout
        ) { [self] line in
            try await handleSSELine(
                line, messagesCount: messagesCount,
                continuation: continuation
            )
        }
        continuation.finish()
    }

    func handleSSELine(
        _ line: String,
        messagesCount: Int,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) throws -> Bool {
        try Task.checkCancellation()
        guard let payload = extractSSEPayload(from: line)
        else { return false }

        let data = Data(payload.utf8)
        guard let eventType = try? Self.sseDecoder.decode(
            EventTypeOnly.self, from: data
        ) else { return false }

        return try dispatchSSEEvent(
            eventType.type, data: data,
            messagesCount: messagesCount, continuation: continuation
        )
    }

    private func dispatchSSEEvent(
        _ type: String,
        data: Data,
        messagesCount: Int,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) throws -> Bool {
        switch type {
        case "response.output_text.delta":
            try handleTextDelta(data: data, continuation: continuation)
        case "response.output_item.added":
            try handleOutputItemAdded(data: data, continuation: continuation)
        case "response.function_call_arguments.delta":
            try handleFunctionCallArgsDelta(
                data: data, continuation: continuation
            )
        case "response.reasoning_summary_text.delta":
            try handleReasoningSummaryDelta(
                data: data, continuation: continuation
            )
        case "response.output_item.done":
            try handleOutputItemDone(data: data, continuation: continuation)
        case "response.completed":
            return try handleCompleted(
                data: data, messagesCount: messagesCount,
                continuation: continuation
            )
        case "response.failed":
            try handleFailed(data: data)
        default:
            break
        }
        return false
    }

    private func handleTextDelta(
        data: Data,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) throws {
        let event = try Self.sseDecoder.decode(
            TextDeltaEvent.self, from: data
        )
        if !event.delta.isEmpty {
            continuation.yield(.delta(.content(event.delta)))
        }
    }

    private func handleOutputItemAdded(
        data: Data,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) throws {
        let event = try Self.sseDecoder.decode(
            OutputItemAddedEvent.self, from: data
        )
        guard event.item.type == "function_call",
              let callId = event.item.callId,
              let name = event.item.name
        else { return }
        continuation.yield(.delta(.toolCallStart(
            index: event.outputIndex, id: callId, name: name
        )))
    }

    private func handleFunctionCallArgsDelta(
        data: Data,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) throws {
        let event = try Self.sseDecoder.decode(
            FunctionCallArgsDeltaEvent.self, from: data
        )
        if !event.delta.isEmpty {
            continuation.yield(.delta(.toolCallDelta(
                index: event.outputIndex, arguments: event.delta
            )))
        }
    }

    private func handleReasoningSummaryDelta(
        data: Data,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) throws {
        let event = try Self.sseDecoder.decode(
            ReasoningSummaryDeltaEvent.self, from: data
        )
        if !event.delta.isEmpty {
            continuation.yield(.delta(.reasoning(event.delta)))
        }
    }

    private func handleOutputItemDone(
        data: Data,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) throws {
        let value = try Self.sseDecoder.decode(
            OutputItemDoneEvent.self, from: data
        )
        guard value.item.type != "message",
              value.item.type != "function_call"
        else { return }
        continuation.yield(.delta(.reasoningDetails([value.item.raw])))
    }

    private func handleCompleted(
        data: Data,
        messagesCount: Int,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) throws -> Bool {
        let event = try Self.sseDecoder.decode(
            CompletedEvent.self, from: data
        )
        let resp = event.response
        lastResponseId = resp.id
        lastMessageCount = messagesCount + 1
        let reasoningTokens =
            resp.usage?.outputTokensDetails?.reasoningTokens ?? 0
        let usage = resp.usage.map { usageData in
            TokenUsage(
                input: usageData.inputTokens,
                output: max(0, usageData.outputTokens - reasoningTokens),
                reasoning: reasoningTokens
            )
        }
        continuation.yield(.delta(.finished(usage: usage)))
        return true
    }

    private func handleFailed(data: Data) throws {
        let event = try Self.sseDecoder.decode(FailedEvent.self, from: data)
        guard let error = event.response.error else {
            throw AgentError.llmError(.other("Response failed"))
        }
        throw AgentError.llmError(
            .other("\(error.code): \(error.message)")
        )
    }
}

private struct EventTypeOnly: Decodable {
    let type: String
}

private struct TextDeltaEvent: Decodable {
    let delta: String
}

private struct OutputItemAddedEvent: Decodable {
    let outputIndex: Int
    let item: OutputItemStub

    enum CodingKeys: String, CodingKey {
        case outputIndex = "output_index"
        case item
    }
}

private struct OutputItemStub: Decodable {
    let type: String
    let callId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case name
    }
}

private struct FunctionCallArgsDeltaEvent: Decodable {
    let outputIndex: Int
    let delta: String

    enum CodingKeys: String, CodingKey {
        case outputIndex = "output_index"
        case delta
    }
}

private struct ReasoningSummaryDeltaEvent: Decodable {
    let delta: String
}

private struct OutputItemDoneEvent: Decodable {
    let item: OutputItemDoneItem
}

private struct OutputItemDoneItem: Decodable {
    let type: String
    let raw: JSONValue

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        type = try container.decode(String.self, forKey: .type)
        raw = try JSONValue(from: decoder)
    }

    private enum TypeKey: String, CodingKey {
        case type
    }
}

private struct CompletedEvent: Decodable {
    let response: ResponsesAPIResponse
}

private struct FailedEvent: Decodable {
    let response: FailedResponseBody
}

private struct FailedResponseBody: Decodable {
    let error: ResponsesErrorDetail?
}
