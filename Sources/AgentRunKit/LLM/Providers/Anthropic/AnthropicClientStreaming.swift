import Foundation

extension AnthropicClient {
    func performStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        toolChoice: AnthropicToolChoice?,
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        try messages.validateForLLMRequest()
        let request = try buildRequest(
            messages: messages, tools: tools,
            stream: true, toolChoice: toolChoice, extraFields: extraFields
        )
        let urlRequest = try buildURLRequest(request)
        let (bytes, httpResponse) = try await HTTPRetry.performStream(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        onResponse?(httpResponse)

        let state = AnthropicStreamState()

        let completed = try await processSSEStream(
            bytes: bytes,
            stallTimeout: retryPolicy.streamStallTimeout
        ) { event in
            try await self.handleSSEEvent(
                event, state: state, continuation: continuation
            )
        }
        guard completed else {
            throw AgentError.llmError(.streamStalled)
        }
        continuation.finish()
    }

    func performRunStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        toolChoice: AnthropicToolChoice?,
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        try messages.validateForLLMRequest()
        let request = try buildRequest(
            messages: messages, tools: tools,
            stream: true, toolChoice: toolChoice, extraFields: extraFields
        )
        let urlRequest = try buildURLRequest(request)
        let (bytes, httpResponse) = try await HTTPRetry.performStream(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        onResponse?(httpResponse)

        let state = AnthropicStreamState()

        let completed = try await processSSEStream(
            bytes: bytes,
            stallTimeout: retryPolicy.streamStallTimeout
        ) { event in
            try await self.handleSSEEvent(event, state: state) { delta in
                continuation.yield(.delta(delta))
            }
        }
        guard completed else {
            throw AgentError.llmError(.streamStalled)
        }

        if await state.isCompleted {
            let blocks = try await state.finalizedBlocks()
            if await state.supportsReplayContinuity(), !blocks.isEmpty {
                let projection = AnthropicTurnProjection(orderedBlocks: blocks)
                continuation.yield(.finalizedContinuity(projection.continuity))
            }
        }
        continuation.finish()
    }

    func handleSSEEvent(
        _ event: SSEEvent,
        state: AnthropicStreamState,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws -> Bool {
        try await handleSSEEvent(event, state: state) { delta in
            continuation.yield(delta)
        }
    }

    func handleSSEEvent(
        _ event: SSEEvent,
        state: AnthropicStreamState,
        yield: @Sendable (StreamDelta) -> Void
    ) async throws -> Bool {
        try await handleSSEPayload(event.data, state: state, yield: yield)
    }

    private func handleSSEPayload(
        _ payload: String,
        state: AnthropicStreamState,
        yield: @Sendable (StreamDelta) -> Void
    ) async throws -> Bool {
        let event = try decodeEvent(AnthropicEventTypeOnly.self, from: Data(payload.utf8))
        guard let eventType = event.type else { return false }

        return try await dispatchEvent(
            eventType, data: Data(payload.utf8),
            state: state, yield: yield
        )
    }

    private func dispatchEvent(
        _ type: AnthropicSSEEvent,
        data: Data,
        state: AnthropicStreamState,
        yield: @Sendable (StreamDelta) -> Void
    ) async throws -> Bool {
        switch type {
        case .messageStart:
            try await handleMessageStart(data: data, state: state)
        case .ping:
            break
        case .contentBlockStart:
            try await handleBlockStart(
                data: data, state: state, yield: yield
            )
        case .contentBlockDelta:
            try await handleBlockDelta(
                data: data, state: state, yield: yield
            )
        case .contentBlockStop:
            try await handleBlockStop(
                data: data, state: state, yield: yield
            )
        case .messageDelta:
            try await handleMessageDelta(data: data, state: state)
        case .messageStop:
            await state.markCompleted()
            await yield(.finished(usage: state.finalUsage()))
            return true
        case .error:
            try handleError(data: data)
        }
        return false
    }

    private func handleBlockStart(
        data: Data,
        state: AnthropicStreamState,
        yield: @Sendable (StreamDelta) -> Void
    ) async throws {
        let event = try decodeEvent(AnthropicBlockStartEvent.self, from: data)
        let block = event.contentBlock
        guard let blockKind = block.kind else {
            await state.setBlockType(event.index, .opaque)
            await state.setOpaqueBlock(event.index, raw: block.raw)
            return
        }

        switch blockKind {
        case .thinking:
            await state.setBlockType(event.index, .thinking)
        case .text:
            await state.setBlockType(event.index, .text)
        case .toolUse:
            let toolIndex = await state.registerToolCall(event.index)
            await state.setBlockType(event.index, .toolUse)
            if let id = block.id, let name = block.name {
                await state.setToolInfo(event.index, id: id, name: name)
                yield(.toolCallStart(
                    index: toolIndex, id: id, name: name, kind: .function
                ))
            }
        }
    }

    private func handleBlockDelta(
        data: Data,
        state: AnthropicStreamState,
        yield: @Sendable (StreamDelta) -> Void
    ) async throws {
        let event = try decodeEvent(AnthropicBlockDeltaEvent.self, from: data)
        let delta = event.delta
        guard let deltaKind = delta.kind else {
            if await state.blockType(for: event.index) == .opaque {
                await state.appendOpaqueDelta(event.index, raw: delta.raw)
            }
            return
        }

        switch deltaKind {
        case .thinkingDelta:
            if let text = delta.thinking, !text.isEmpty {
                await state.appendThinking(event.index, text)
                yield(.reasoning(text))
            }
        case .textDelta:
            if let text = delta.text, !text.isEmpty {
                await state.appendTextContent(event.index, text)
                yield(.content(text))
            }
        case .inputJsonDelta:
            if let json = delta.partialJson, !json.isEmpty {
                guard let toolIndex = await state.toolCallIndex(for: event.index) else {
                    throw AgentError.malformedStream(.toolCallDeltaWithoutStart(index: event.index))
                }
                await state.appendToolInput(event.index, json)
                yield(.toolCallDelta(
                    index: toolIndex, arguments: json
                ))
            }
        case .signatureDelta:
            if let sig = delta.signature {
                await state.appendSignature(event.index, sig)
            }
        }
    }

    private func handleBlockStop(
        data: Data,
        state: AnthropicStreamState,
        yield: @Sendable (StreamDelta) -> Void
    ) async throws {
        let event = try decodeEvent(AnthropicBlockStopEvent.self, from: data)
        let blockType = await state.blockType(for: event.index)

        if blockType == .thinking {
            let thinking = await state.thinking(for: event.index)
            let signature = await state.signature(for: event.index)
            if let thinking, let signature {
                yield(.reasoningDetails([
                    .object([
                        "type": .string("thinking"),
                        "thinking": .string(thinking),
                        "signature": .string(signature)
                    ])
                ]))
            }
        }
    }

    private func handleMessageStart(
        data: Data,
        state: AnthropicStreamState
    ) async throws {
        let event = try decodeEvent(AnthropicMessageStartEvent.self, from: data)
        await state.setInputUsage(event.message.usage)
    }

    private func handleMessageDelta(
        data: Data,
        state: AnthropicStreamState
    ) async throws {
        let event = try decodeEvent(AnthropicMessageDeltaEvent.self, from: data)
        await state.setOutputTokens(event.usage?.outputTokens ?? 0)
    }

    private func handleError(data: Data) throws {
        let event = try decodeEvent(AnthropicStreamErrorEvent.self, from: data)
        throw AgentError.llmError(
            .other("\(event.error.type): \(event.error.message)")
        )
    }

    private func decodeEvent<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AgentError.llmError(.decodingFailed(error))
        }
    }
}

extension AnthropicClient: HistoryRewriteAwareClient {
    func streamForRun(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?,
        requestMode _: RunRequestMode
    ) -> AsyncThrowingStream<RunStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performRunStreamRequest(
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

private enum AnthropicSSEEvent: String {
    case messageStart = "message_start"
    case contentBlockStart = "content_block_start"
    case contentBlockDelta = "content_block_delta"
    case contentBlockStop = "content_block_stop"
    case messageDelta = "message_delta"
    case messageStop = "message_stop"
    case ping, error
}

private enum AnthropicBlockKind: String {
    case thinking, text
    case toolUse = "tool_use"
}

private enum AnthropicDeltaKind: String {
    case thinkingDelta = "thinking_delta"
    case textDelta = "text_delta"
    case inputJsonDelta = "input_json_delta"
    case signatureDelta = "signature_delta"
}

private struct AnthropicEventTypeOnly: Decodable {
    let type: AnthropicSSEEvent?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try AnthropicSSEEvent(rawValue: container.decode(String.self, forKey: .type))
    }

    private enum CodingKeys: String, CodingKey { case type }
}

private struct AnthropicBlockStartEvent: Decodable {
    let index: Int
    let contentBlock: AnthropicBlockStartContent

    enum CodingKeys: String, CodingKey {
        case index
        case contentBlock = "content_block"
    }
}

private struct AnthropicBlockStartContent: Decodable {
    let kind: AnthropicBlockKind?
    let rawType: String
    let id: String?
    let name: String?
    let raw: JSONValue

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawType = try container.decode(String.self, forKey: .type)
        kind = AnthropicBlockKind(rawValue: rawType)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        raw = try JSONValue(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, name
    }
}

private struct AnthropicBlockDeltaEvent: Decodable {
    let index: Int
    let delta: AnthropicDeltaContent
}

private struct AnthropicDeltaContent: Decodable {
    let kind: AnthropicDeltaKind?
    let text: String?
    let thinking: String?
    let partialJson: String?
    let signature: String?
    let raw: JSONValue

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try AnthropicDeltaKind(rawValue: container.decode(String.self, forKey: .type))
        text = try container.decodeIfPresent(String.self, forKey: .text)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        partialJson = try container.decodeIfPresent(String.self, forKey: .partialJson)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        raw = try JSONValue(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, signature
        case partialJson = "partial_json"
    }
}

private struct AnthropicBlockStopEvent: Decodable { let index: Int }
private struct AnthropicMessageDeltaEvent: Decodable { let usage: AnthropicDeltaUsage? }

private struct AnthropicDeltaUsage: Decodable {
    let outputTokens: Int
    enum CodingKeys: String, CodingKey { case outputTokens = "output_tokens" }
}

private struct AnthropicMessageStartEvent: Decodable { let message: AnthropicMessageStartMessage }
private struct AnthropicMessageStartMessage: Decodable { let usage: AnthropicUsage }
private struct AnthropicStreamErrorEvent: Decodable { let error: AnthropicErrorDetail }
