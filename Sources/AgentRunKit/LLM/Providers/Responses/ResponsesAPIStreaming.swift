import Foundation

extension ResponsesAPIClient {
    private static let sseDecoder = JSONDecoder()

    func performStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        requestMode: RunRequestMode = .auto,
        options: ResponsesRequestOptions?,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        try messages.validateForLLMRequest()
        if shouldResetConversationBeforeRequest(messages: messages, requestMode: requestMode) {
            resetConversation()
        }
        let request = try buildRequest(
            messages: messages, tools: tools,
            stream: true, extraFields: extraFields,
            requestMode: requestMode, options: options
        )
        let urlRequest = try buildURLRequest(request)
        let (bytes, httpResponse) = try await HTTPRetry.performStream(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        onResponse?(httpResponse)
        pendingInputMessages = messages
        try await processRunStreamBytes(
            bytes: bytes,
            messagesCount: messages.count,
            stallTimeout: retryPolicy.streamStallTimeout,
            continuation: continuation
        )
    }

    func processRunStreamBytes<S: AsyncSequence & Sendable>(
        bytes: S,
        messagesCount: Int,
        stallTimeout: Duration?,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws where S.Element == UInt8 {
        let completionState = ResponsesStreamCompletionState()
        let semanticState = ResponsesStreamState()
        try await processSSEStream(bytes: bytes, stallTimeout: stallTimeout) { [self] event in
            let didComplete = try await handleSSEEvent(
                event,
                messagesCount: messagesCount,
                semanticState: semanticState,
                continuation: continuation
            )
            if didComplete {
                await completionState.markCompleted()
            }
            return didComplete
        }
        guard await completionState.isCompleted else {
            throw AgentError.malformedStream(.responsesStreamIncomplete)
        }
        continuation.finish()
    }

    private func handleSSEEvent(
        _ event: SSEEvent,
        messagesCount: Int,
        semanticState: ResponsesStreamState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws -> Bool {
        try await handleSSEPayload(
            event.data,
            messagesCount: messagesCount,
            semanticState: semanticState,
            continuation: continuation
        )
    }

    private func handleSSEPayload(
        _ payload: String,
        messagesCount: Int,
        semanticState: ResponsesStreamState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws -> Bool {
        let data = Data(payload.utf8)
        let eventType = try Self.sseDecoder.decode(EventTypeOnly.self, from: data).type

        return try await dispatchSSEEvent(
            eventType,
            data: data,
            messagesCount: messagesCount,
            semanticState: semanticState,
            continuation: continuation
        )
    }

    private func dispatchSSEEvent(
        _ type: String,
        data: Data,
        messagesCount: Int,
        semanticState: ResponsesStreamState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws -> Bool {
        switch type {
        case "response.output_text.delta":
            try await handleTextDelta(
                data: data,
                semanticState: semanticState,
                continuation: continuation
            )
        case "response.output_item.added":
            try await handleOutputItemAdded(
                data: data,
                semanticState: semanticState,
                continuation: continuation
            )
        case "response.function_call_arguments.delta",
             "response.custom_tool_call_input.delta":
            try await handleToolCallArgsDelta(
                data: data,
                semanticState: semanticState,
                continuation: continuation
            )
        case "response.reasoning_summary_text.delta":
            try await handleReasoningSummaryDelta(
                data: data,
                semanticState: semanticState,
                continuation: continuation
            )
        case "response.output_item.done":
            try await handleOutputItemDone(
                data: data,
                semanticState: semanticState,
                continuation: continuation
            )
        case "response.completed":
            return try await handleCompleted(
                data: data,
                messagesCount: messagesCount,
                semanticState: semanticState,
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
        semanticState: ResponsesStreamState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        let event = try Self.sseDecoder.decode(
            TextDeltaEvent.self, from: data
        )
        if !event.delta.isEmpty {
            let delta = StreamDelta.content(event.delta)
            await semanticState.record(delta)
            continuation.yield(.delta(delta))
        }
    }

    private func handleOutputItemAdded(
        data: Data,
        semanticState: ResponsesStreamState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        let event = try Self.sseDecoder.decode(
            OutputItemAddedEvent.self, from: data
        )
        let kind: ToolCallKind
        switch event.item.type {
        case "function_call":
            kind = .function
        case "custom_tool_call":
            kind = .custom
        case "mcp_call", "computer_call", "apply_patch_call":
            throw AgentError.llmError(.featureUnsupported(
                provider: "responses",
                feature: "\(event.item.type) streaming"
            ))
        default:
            return
        }
        guard let callId = event.item.callId, let name = event.item.name else { return }
        let delta = StreamDelta.toolCallStart(
            index: event.outputIndex,
            id: callId,
            name: name,
            kind: kind
        )
        await semanticState.record(delta)
        continuation.yield(.delta(delta))
    }

    private func handleToolCallArgsDelta(
        data: Data,
        semanticState: ResponsesStreamState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        let event = try Self.sseDecoder.decode(
            ToolCallArgsDeltaEvent.self, from: data
        )
        if !event.delta.isEmpty {
            let delta = StreamDelta.toolCallDelta(
                index: event.outputIndex,
                arguments: event.delta
            )
            await semanticState.record(delta)
            continuation.yield(.delta(delta))
        }
    }

    private func handleReasoningSummaryDelta(
        data: Data,
        semanticState: ResponsesStreamState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        let event = try Self.sseDecoder.decode(
            ReasoningSummaryDeltaEvent.self, from: data
        )
        if !event.delta.isEmpty {
            if let separator = await semanticState.summaryPartSeparator(
                forOutput: event.outputIndex, summary: event.summaryIndex
            ) {
                let sepDelta = StreamDelta.reasoning(separator)
                await semanticState.record(sepDelta)
                continuation.yield(.delta(sepDelta))
            }
            let delta = StreamDelta.reasoning(event.delta)
            await semanticState.record(delta)
            continuation.yield(.delta(delta))
        }
    }

    private func handleOutputItemDone(
        data: Data,
        semanticState: ResponsesStreamState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        let value = try Self.sseDecoder.decode(
            OutputItemDoneEvent.self, from: data
        )
        guard value.item.type == "reasoning" else { return }
        let delta = StreamDelta.reasoningDetails([value.item.raw])
        await semanticState.record(delta)
        continuation.yield(.delta(delta))
    }

    private func handleCompleted(
        data: Data,
        messagesCount: Int,
        semanticState: ResponsesStreamState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws -> Bool {
        let event: CompletedEvent
        do {
            event = try Self.sseDecoder.decode(
                CompletedEvent.self, from: data
            )
        } catch {
            throw AgentError.llmError(.decodingFailed(error))
        }
        let resp = event.response
        try checkResponseError(resp)
        let projection = projectResponse(resp)
        let reconciliationDeltas = try await semanticState.reconciliationDeltas(
            response: resp,
            projection: projection
        )
        for delta in reconciliationDeltas {
            continuation.yield(.delta(delta))
        }
        lastResponseId = resp.id
        lastMessageCount = messagesCount + 1
        if let inputMessages = pendingInputMessages {
            lastPrefixSignature = prefixSignature(inputMessages + [.assistant(projection.assistantMessage)])
            pendingInputMessages = nil
        }
        if let continuity = projection.continuity {
            continuation.yield(.finalizedContinuity(continuity))
        }
        continuation.yield(.delta(.finished(usage: projection.tokenUsage)))
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

private struct EventTypeOnly: Decodable { let type: String }
private struct TextDeltaEvent: Decodable { let delta: String }
private struct OutputItemAddedEvent: Decodable {
    let outputIndex: Int
    let item: OutputItemStub
    enum CodingKeys: String, CodingKey { case outputIndex = "output_index", item }
}

private struct OutputItemStub: Decodable {
    let type: String
    let callId: String?
    let name: String?
    enum CodingKeys: String, CodingKey { case type, callId = "call_id", name }
}

private struct ToolCallArgsDeltaEvent: Decodable {
    let outputIndex: Int
    let delta: String
    enum CodingKeys: String, CodingKey { case outputIndex = "output_index", delta }
}

private struct ReasoningSummaryDeltaEvent: Decodable {
    let delta: String
    let outputIndex: Int?
    let summaryIndex: Int?
    enum CodingKeys: String, CodingKey { case delta, outputIndex = "output_index", summaryIndex = "summary_index" }
}

private struct OutputItemDoneEvent: Decodable { let item: OutputItemDoneItem }
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

private struct CompletedEvent: Decodable { let response: ResponsesAPIResponse }
private struct FailedEvent: Decodable { let response: FailedResponseBody }
private struct FailedResponseBody: Decodable { let error: ResponsesErrorDetail? }
