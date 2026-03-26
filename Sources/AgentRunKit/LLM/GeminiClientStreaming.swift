import Foundation

extension GeminiClient {
    func performStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        let request = try buildRequest(
            messages: messages, tools: tools, extraFields: extraFields
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
        ) { line in
            try await self.handleSSELine(
                line, state: state, continuation: continuation
            )
        }
        continuation.finish()
    }

    func handleSSELine(
        _ line: String,
        state: GeminiStreamState,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard let payload = extractSSEPayload(from: line) else { return false }

        let data = Data(payload.utf8)

        if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
            throw AgentError.llmError(
                .other("\(errorResponse.error.status): \(errorResponse.error.message)")
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
                let toolIndex = await state.incrementToolCallCount()
                let callId = functionCall.id ?? "gemini_call_\(toolIndex)"
                continuation.yield(.toolCallStart(
                    index: toolIndex, id: callId, name: functionCall.name
                ))

                let arguments: String
                if let args = functionCall.args,
                   let encoded = try? JSONEncoder().encode(args),
                   let str = String(data: encoded, encoding: .utf8) {
                    arguments = str
                } else {
                    arguments = "{}"
                }
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
                } else if !text.isEmpty {
                    continuation.yield(.content(text))
                }
            }
        }

        if let finishReason = candidate.finishReason,
           finishReason == "STOP" || finishReason == "MAX_TOKENS" {
            let thinkingBlocks = await state.buildReasoningDetails()
            if !thinkingBlocks.isEmpty {
                continuation.yield(.reasoningDetails(thinkingBlocks))
            }

            let usage = response.usageMetadata
            let thoughtsTokenCount = usage?.thoughtsTokenCount ?? 0
            let candidatesTokenCount = usage?.candidatesTokenCount ?? 0
            let outputTokens = max(0, candidatesTokenCount - thoughtsTokenCount)

            let tokenUsage = TokenUsage(
                input: usage?.promptTokenCount ?? 0,
                output: outputTokens,
                reasoning: thoughtsTokenCount,
                cacheRead: usage?.cachedContentTokenCount
            )
            continuation.yield(.finished(usage: tokenUsage))
            return true
        }

        return false
    }
}

// MARK: - Stream State

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
