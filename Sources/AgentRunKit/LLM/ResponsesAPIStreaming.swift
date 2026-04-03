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
        let completionState = StreamCompletionState()
        let semanticState = ResponsesStreamingSemanticState()
        try await processSSEStream(bytes: bytes, stallTimeout: stallTimeout) { [self] line in
            let didComplete = try await handleSSELine(
                line,
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

    private func handleSSELine(
        _ line: String,
        messagesCount: Int,
        semanticState: ResponsesStreamingSemanticState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard let payload = extractSSEPayload(from: line)
        else { return false }

        let data = Data(payload.utf8)
        guard let eventType = try? Self.sseDecoder.decode(
            EventTypeOnly.self, from: data
        ) else { return false }

        return try await dispatchSSEEvent(
            eventType.type, data: data,
            messagesCount: messagesCount,
            semanticState: semanticState,
            continuation: continuation
        )
    }

    private func dispatchSSEEvent(
        _ type: String,
        data: Data,
        messagesCount: Int,
        semanticState: ResponsesStreamingSemanticState,
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
        case "response.function_call_arguments.delta":
            try await handleFunctionCallArgsDelta(
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
        semanticState: ResponsesStreamingSemanticState,
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
        semanticState: ResponsesStreamingSemanticState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        let event = try Self.sseDecoder.decode(
            OutputItemAddedEvent.self, from: data
        )
        guard event.item.type == "function_call",
              let callId = event.item.callId,
              let name = event.item.name
        else { return }
        let delta = StreamDelta.toolCallStart(
            index: event.outputIndex,
            id: callId,
            name: name
        )
        await semanticState.record(delta)
        continuation.yield(.delta(delta))
    }

    private func handleFunctionCallArgsDelta(
        data: Data,
        semanticState: ResponsesStreamingSemanticState,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        let event = try Self.sseDecoder.decode(
            FunctionCallArgsDeltaEvent.self, from: data
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
        semanticState: ResponsesStreamingSemanticState,
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
        semanticState: ResponsesStreamingSemanticState,
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
        semanticState: ResponsesStreamingSemanticState,
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

private struct FunctionCallArgsDeltaEvent: Decodable {
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

private actor StreamCompletionState {
    private(set) var isCompleted = false
    func markCompleted() {
        isCompleted = true
    }
}

private actor ResponsesStreamingSemanticState {
    private var content = ""
    private var reasoning = ""
    private var reasoningDetails: [JSONValue] = []
    private var toolCalls: [Int: ResponsesStreamedToolCall] = [:]
    private var lastSummaryPart: (outputIndex: Int, summaryIndex: Int)?
    private var summaryPartCount = 0

    func summaryPartSeparator(forOutput outputIndex: Int?, summary summaryIndex: Int?) -> String? {
        guard let summaryIndex else { return nil }
        if let outputIndex {
            let current = (outputIndex, summaryIndex)
            defer { lastSummaryPart = current }
            guard let last = lastSummaryPart,
                  current.0 != last.outputIndex || current.1 != last.summaryIndex
            else { return nil }
            return "\n"
        }
        defer { summaryPartCount += 1 }
        return summaryPartCount > 0 ? "\n" : nil
    }

    func record(_ delta: StreamDelta) {
        switch delta {
        case let .content(text):
            content += text
        case let .reasoning(text):
            reasoning += text
        case let .reasoningDetails(details):
            reasoningDetails.append(contentsOf: details)
        case let .toolCallStart(index, id, name):
            toolCalls[index] = ResponsesStreamedToolCall(
                id: id,
                name: name,
                arguments: toolCalls[index]?.arguments ?? ""
            )
        case let .toolCallDelta(index, arguments):
            let existing = toolCalls[index]
            toolCalls[index] = ResponsesStreamedToolCall(
                id: existing?.id,
                name: existing?.name,
                arguments: (existing?.arguments ?? "") + arguments
            )
        case .audioData, .audioTranscript, .audioStarted, .finished:
            break
        }
    }

    func reconciliationDeltas(
        response: ResponsesAPIResponse,
        projection: ResponsesAPIClient.ResponsesTurnProjection
    ) throws -> [StreamDelta] {
        let target = try ResponsesCompletedSemanticTarget(response: response, projection: projection)
        var deltas: [StreamDelta] = []

        guard let reasoningSuffix = utf8Suffix(of: target.reasoning, afterPrefix: reasoning) else {
            throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
        }
        if !reasoningSuffix.isEmpty {
            reasoning += reasoningSuffix
            deltas.append(.reasoning(reasoningSuffix))
        }

        guard target.reasoningDetails.count >= reasoningDetails.count,
              Array(target.reasoningDetails.prefix(reasoningDetails.count)) == reasoningDetails
        else {
            throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
        }
        let reasoningDetailSuffix = Array(target.reasoningDetails.dropFirst(reasoningDetails.count))
        if !reasoningDetailSuffix.isEmpty {
            reasoningDetails += reasoningDetailSuffix
            deltas.append(.reasoningDetails(reasoningDetailSuffix))
        }

        guard let contentSuffix = utf8Suffix(of: target.content, afterPrefix: content) else {
            throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
        }
        if !contentSuffix.isEmpty {
            content += contentSuffix
            deltas.append(.content(contentSuffix))
        }

        let targetIndices = Set(target.toolCalls.keys)
        guard Set(toolCalls.keys).isSubset(of: targetIndices) else {
            throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
        }

        for (index, targetCall) in target.toolCalls.sorted(by: { $0.key < $1.key }) {
            if let existing = toolCalls[index] {
                guard existing.id == nil || existing.id == targetCall.id,
                      existing.name == nil || existing.name == targetCall.name,
                      let argumentsSuffix = utf8Suffix(
                          of: targetCall.arguments,
                          afterPrefix: existing.arguments
                      )
                else {
                    throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
                }
                if existing.id == nil, let id = targetCall.id, let name = targetCall.name {
                    deltas.append(.toolCallStart(index: index, id: id, name: name))
                }
                if !argumentsSuffix.isEmpty {
                    toolCalls[index] = ResponsesStreamedToolCall(
                        id: existing.id ?? targetCall.id,
                        name: existing.name ?? targetCall.name,
                        arguments: existing.arguments + argumentsSuffix
                    )
                    deltas.append(.toolCallDelta(index: index, arguments: argumentsSuffix))
                }
            } else if let id = targetCall.id, let name = targetCall.name {
                toolCalls[index] = targetCall
                deltas.append(.toolCallStart(index: index, id: id, name: name))
                if !targetCall.arguments.isEmpty {
                    deltas.append(.toolCallDelta(index: index, arguments: targetCall.arguments))
                }
            }
        }

        return deltas
    }
}

private func utf8Suffix(of target: String, afterPrefix prefix: String) -> String? {
    let targetBytes = Array(target.utf8)
    let prefixBytes = Array(prefix.utf8)
    guard targetBytes.starts(with: prefixBytes) else { return nil }
    return String(bytes: targetBytes.dropFirst(prefixBytes.count), encoding: .utf8)
}

private struct ResponsesStreamedToolCall: Equatable {
    let id: String?
    let name: String?
    let arguments: String
}

private struct ResponsesCompletedSemanticTarget {
    let content: String
    let reasoning: String
    let reasoningDetails: [JSONValue]
    let toolCalls: [Int: ResponsesStreamedToolCall]

    init(
        response: ResponsesAPIResponse,
        projection: ResponsesAPIClient.ResponsesTurnProjection
    ) throws {
        content = projection.content
        reasoning = projection.reasoning?.content ?? ""
        reasoningDetails = projection.reasoningDetails ?? []

        var indexedToolCalls: [Int: ResponsesStreamedToolCall] = [:]
        for (index, outputItem) in response.output.enumerated() {
            guard case let .functionCall(call) = outputItem else { continue }
            indexedToolCalls[index] = ResponsesStreamedToolCall(
                id: call.callId,
                name: call.name,
                arguments: call.arguments
            )
        }
        toolCalls = indexedToolCalls
    }
}
