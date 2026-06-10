import Foundation

extension OpenAIClient {
    func performStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        options: OpenAIChatRequestOptions?,
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        try messages.validateForLLMRequest()
        let request = try buildRequest(
            messages: messages,
            tools: tools,
            stream: true,
            extraFields: extraFields,
            options: options
        )
        let urlRequest = try buildURLRequest(request)
        let (bytes, httpResponse) = try await HTTPRetry.performStream(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        onResponse?(httpResponse)
        let state = OpenAIChatStreamState()
        let completion = try await processSSEStream(
            bytes: bytes,
            provider: providerIdentifier,
            stallTimeout: retryPolicy.streamStallTimeout
        ) { [self] event, diagnostics in
            try await handleSSEEvent(event, state: state, diagnostics: diagnostics, continuation: continuation)
        }
        guard completion.diagnostics.finishSignalSeen else {
            throw AgentError.llmError(.streamFailed(.finishedDeltaMissing(
                diagnostics: completion.diagnostics
            )))
        }
        await continuation.yield(.finished(usage: state.usage))
        continuation.yield(.streamClosed(terminalMarkerSeen: completion.terminalMarkerSeen))
        continuation.finish()
    }

    private func handleSSEEvent(
        _ event: SSEEvent,
        state: OpenAIChatStreamState,
        diagnostics: StreamFailureDiagnostics,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws -> SSEDisposition {
        try await handleSSEPayload(event.data, state: state, diagnostics: diagnostics, continuation: continuation)
    }

    private func handleSSEPayload(
        _ payload: String,
        state: OpenAIChatStreamState,
        diagnostics: StreamFailureDiagnostics,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws -> SSEDisposition {
        if payload == "[DONE]" {
            return .complete
        }
        let chunkData = Data(payload.utf8)
        let chunk = try parseStreamingChunk(chunkData)
        if let error = chunk.error {
            throw AgentError.llmError(.streamFailed(.providerError(
                code: error.code,
                message: error.resolvedMessage,
                diagnostics: diagnostics
            )))
        }
        if chunk.choices?.contains(where: { $0.finishReason == "error" }) == true {
            throw AgentError.llmError(.streamFailed(.providerError(
                code: nil,
                message: "Stream terminated with finish_reason 'error' and no error payload",
                diagnostics: diagnostics
            )))
        }
        if let details = try JSONValue.extractReasoningDetails(from: chunkData) {
            continuation.yield(.reasoningDetails(details))
        }
        for delta in try extractDeltas(from: chunk) {
            continuation.yield(delta)
        }
        if let usage = chunk.usage {
            await state.recordUsage(usage.tokenUsage)
        }
        return chunk.choices?.contains(where: { $0.finishReason != nil }) == true ? .completeOnEOF : .continue
    }

    func performUploadWithRetry<T>(
        urlRequest: URLRequest,
        bodyFileURL: URL,
        onResponse: (@Sendable (HTTPURLResponse) -> Void)? = nil,
        onSuccess: (Data, HTTPURLResponse) throws -> T
    ) async throws -> T {
        var lastError: (any Error)?
        var sleptForRetryAfter = false

        for attempt in 0 ..< retryPolicy.maxAttempts {
            try Task.checkCancellation()
            if attempt > 0, !sleptForRetryAfter {
                try await Task.sleep(for: retryPolicy.delay(forAttempt: attempt - 1))
            }
            sleptForRetryAfter = false

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.upload(for: urlRequest, fromFile: bodyFileURL)
            } catch {
                if HTTPRetry.isCancellation(error) {
                    throw CancellationError()
                }
                lastError = TransportError.networkError(error)
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AgentError.llmError(.invalidResponse)
            }

            if (200 ... 299).contains(httpResponse.statusCode) {
                onResponse?(httpResponse)
                return try onSuccess(data, httpResponse)
            }

            let result = try await HTTPRetry.handleErrorStatus(
                httpResponse: httpResponse,
                errorBody: String(data: data, encoding: .utf8) ?? "",
                attempt: attempt,
                retryPolicy: retryPolicy,
                sleptForRetryAfter: &sleptForRetryAfter
            )

            switch result {
            case .continue: continue
            case let .stop(error): lastError = error
            }

            if !retryPolicy.isRetryable(statusCode: httpResponse.statusCode) { break }
        }

        let transportError = lastError as? TransportError
            ?? .other(lastError.map { String(describing: $0) } ?? "Unknown error")
        throw AgentError.llmError(transportError)
    }

    func parseStreamingChunk(_ data: Data) throws -> StreamingChunk {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(StreamingChunk.self, from: data)
        } catch {
            throw AgentError.llmError(.decodingFailed(error))
        }
    }

    func extractDeltas(from chunk: StreamingChunk) throws -> [StreamDelta] {
        var deltas: [StreamDelta] = []
        for choice in chunk.choices ?? [] {
            if let reasoning = choice.delta.reasoning ?? choice.delta.reasoningContent, !reasoning.isEmpty {
                deltas.append(.reasoning(reasoning))
            }
            if let content = choice.delta.content, !content.isEmpty {
                deltas.append(.content(content))
            }
            try extractToolCallDeltas(from: choice.delta, into: &deltas)
            try extractAudioDeltas(from: choice.delta, into: &deltas)
        }
        return deltas
    }

    private func extractToolCallDeltas(
        from delta: StreamingDelta,
        into deltas: inout [StreamDelta]
    ) throws {
        guard let toolCalls = delta.toolCalls else { return }
        for call in toolCalls {
            let kind = try resolveToolCallKind(call)
            let name = call.function?.name ?? call.custom?.name
            if let id = call.id, !id.isEmpty, let name, !name.isEmpty {
                deltas.append(.toolCallStart(index: call.index, id: id, name: name, kind: kind))
            }
            let payload = call.function?.arguments ?? call.custom?.input
            if let payload, !payload.isEmpty {
                deltas.append(.toolCallDelta(index: call.index, arguments: payload))
            }
        }
    }

    private func resolveToolCallKind(_ call: StreamingToolCall) throws -> ToolCallKind {
        if let rawType = call.type {
            guard let kind = ToolCallKind(rawValue: rawType) else {
                throw AgentError.llmError(.featureUnsupported(
                    provider: "openai-chat",
                    feature: "streaming tool call type '\(rawType)'"
                ))
            }
            return kind
        }
        return call.custom != nil ? .custom : .function
    }

    private func extractAudioDeltas(from delta: StreamingDelta, into deltas: inout [StreamDelta]) throws {
        guard let audio = delta.audio else { return }
        if let id = audio.id, !id.isEmpty {
            deltas.append(.audioStarted(id: id, expiresAt: audio.expiresAt ?? 0))
        }
        if let base64 = audio.data, !base64.isEmpty {
            guard let decoded = Data(base64Encoded: base64) else {
                throw AgentError.llmError(.decodingFailed(
                    description: "Invalid base64 in audio data"
                ))
            }
            deltas.append(.audioData(decoded))
        }
        if let transcript = audio.transcript, !transcript.isEmpty {
            deltas.append(.audioTranscript(transcript))
        }
    }
}

actor OpenAIChatStreamState {
    private(set) var usage: TokenUsage?

    func recordUsage(_ usage: TokenUsage) {
        self.usage = usage
    }
}
