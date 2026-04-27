import Foundation

extension GeminiClient {
    func performStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        functionCallingMode: GeminiFunctionCallingMode,
        allowedFunctionNames: [String]?,
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        try messages.validateForLLMRequest()
        let request = try buildRequest(
            messages: messages,
            tools: tools,
            functionCallingMode: functionCallingMode,
            allowedFunctionNames: allowedFunctionNames,
            extraFields: extraFields
        )
        let urlRequest = try buildURLRequest(request, stream: true)
        let (bytes, httpResponse) = try await HTTPRetry.performStream(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        onResponse?(httpResponse)

        let state = GeminiStreamState()

        try await processSSEStream(
            bytes: bytes,
            stallTimeout: retryPolicy.streamStallTimeout
        ) { event, _ in
            try await self.handleSSEEvent(
                event, state: state, providerIdentifier: self.providerIdentifier, continuation: continuation
            )
        }
        continuation.finish()
    }

    func handleSSEEvent(
        _ event: SSEEvent,
        state: GeminiStreamState,
        providerIdentifier: ProviderIdentifier = .gemini,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws -> Bool {
        try await handleSSEPayload(
            event.data, state: state, providerIdentifier: providerIdentifier, continuation: continuation
        )
    }

    private func handleSSEPayload(
        _ payload: String,
        state: GeminiStreamState,
        providerIdentifier: ProviderIdentifier,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws -> Bool {
        let data = Data(payload.utf8)

        if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
            throw AgentError.llmError(
                .streamFailed(.providerError(
                    provider: providerIdentifier,
                    code: errorResponse.error.status,
                    message: errorResponse.error.message
                ))
            )
        }

        let response: GeminiResponse
        do {
            response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            throw AgentError.llmError(.decodingFailed(error))
        }

        guard let candidate = response.candidates?.first else { return false }

        for part in candidate.content?.parts ?? [] {
            if let functionCall = part.functionCall {
                await state.flushThinkingBlock()
                let toolIndex = await state.incrementToolCallCount()
                let callId = functionCall.id ?? "gemini_call_\(toolIndex)"
                if let signature = part.thoughtSignature, !signature.isEmpty {
                    continuation.yield(.reasoningDetails([
                        GeminiReasoningDetail.functionCallSignature(
                            toolCallID: callId,
                            signature: signature
                        )
                    ]))
                }
                continuation.yield(.toolCallStart(
                    index: toolIndex, id: callId, name: functionCall.name, kind: .function
                ))
                let arguments = try encodeFunctionCallArgs(functionCall.args)
                continuation.yield(.toolCallDelta(
                    index: toolIndex, arguments: arguments
                ))
            } else if let text = part.text {
                if part.thought == true {
                    if !text.isEmpty {
                        await state.appendThinking(text)
                        continuation.yield(.reasoning(text))
                    }
                    if let signature = part.thoughtSignature {
                        await state.appendSignature(signature)
                    }
                } else {
                    await state.flushThinkingBlock()
                    if !text.isEmpty {
                        continuation.yield(.content(text))
                    }
                }
            }
        }

        if candidate.finishReason != nil {
            let thinkingBlocks = await state.buildReasoningDetails()
            if !thinkingBlocks.isEmpty {
                continuation.yield(.reasoningDetails(thinkingBlocks))
            }

            continuation.yield(.finished(usage: response.usageMetadata?.tokenUsage))
            return true
        }

        return false
    }
}

actor GeminiStreamState {
    private(set) var toolCallCount: Int = 0
    private var thinkingChunks: [(text: String, signature: String?)] = []
    private var currentThinkingText: String = ""
    private var currentSignature: String?

    func incrementToolCallCount() -> Int {
        defer { toolCallCount += 1 }
        return toolCallCount
    }

    func appendThinking(_ text: String) {
        currentThinkingText += text
    }

    func appendSignature(_ signature: String) {
        if let existing = currentSignature {
            currentSignature = existing + signature
        } else {
            currentSignature = signature
        }
    }

    func flushThinkingBlock() {
        guard !currentThinkingText.isEmpty else { return }
        thinkingChunks.append((text: currentThinkingText, signature: currentSignature))
        currentThinkingText = ""
        currentSignature = nil
    }

    func buildReasoningDetails() -> [JSONValue] {
        flushThinkingBlock()
        return thinkingChunks.map { chunk in
            var dict: [String: JSONValue] = [
                "type": .string("thinking"),
                "thinking": .string(chunk.text)
            ]
            if let sig = chunk.signature {
                dict["signature"] = .string(sig)
            }
            return .object(dict)
        }
    }
}
