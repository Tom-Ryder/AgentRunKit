import Foundation

public struct OpenAIClient: LLMClient, Sendable {
    public let modelIdentifier: String
    public let maxTokens: Int
    let apiKey: String
    let baseURL: URL
    let session: URLSession
    let retryPolicy: RetryPolicy

    public init(
        apiKey: String,
        model: String,
        maxTokens: Int = 128_000,
        baseURL: URL,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default
    ) {
        self.apiKey = apiKey
        modelIdentifier = model
        self.maxTokens = maxTokens
        self.baseURL = baseURL
        self.session = session
        self.retryPolicy = retryPolicy
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat? = nil
    ) async throws -> AssistantMessage {
        let request = buildRequest(messages: messages, tools: tools, responseFormat: responseFormat)
        let urlRequest = try buildURLRequest(request)
        return try await performWithRetry(urlRequest: urlRequest) { data, _ in
            try parseResponse(data)
        }
    }

    public func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStreamRequest(
                        messages: messages,
                        tools: tools,
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

extension OpenAIClient {
    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        stream: Bool = false,
        responseFormat: ResponseFormat? = nil
    ) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: modelIdentifier,
            messages: messages.map(RequestMessage.init),
            tools: tools.isEmpty ? nil : tools.map(RequestTool.init),
            toolChoice: tools.isEmpty ? nil : "auto",
            maxTokens: maxTokens,
            stream: stream ? true : nil,
            streamOptions: stream ? StreamOptions(includeUsage: true) : nil,
            responseFormat: responseFormat
        )
    }

    func buildURLRequest(_ request: ChatCompletionRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        do {
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw AgentError.llmError(.encodingFailed(error))
        }
        return urlRequest
    }

    func parseResponse(_ data: Data) throws -> AssistantMessage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response: ChatCompletionResponse
        do {
            response = try decoder.decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw AgentError.llmError(.decodingFailed(error))
        }

        guard let choice = response.choices.first else {
            throw AgentError.llmError(.noChoices)
        }

        let toolCalls = (choice.message.toolCalls ?? []).map { call in
            ToolCall(id: call.id, name: call.function.name, arguments: call.function.arguments)
        }

        let tokenUsage = response.usage.map { usage in
            let reasoning = usage.completionTokensDetails?.reasoningTokens ?? 0
            let outputMinusReasoning = max(0, usage.completionTokens - reasoning)
            return TokenUsage(
                input: usage.promptTokens,
                output: outputMinusReasoning,
                reasoning: reasoning
            )
        }

        return AssistantMessage(
            content: choice.message.content ?? "",
            toolCalls: toolCalls,
            tokenUsage: tokenUsage
        )
    }
}

extension OpenAIClient {
    enum RetryResult {
        case `continue`
        case stop(any Error)
    }

    func performStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        let request = buildRequest(messages: messages, tools: tools, stream: true)
        let urlRequest = try buildURLRequest(request)

        try await performStreamWithRetry(urlRequest: urlRequest) { bytes in
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" {
                    continuation.finish()
                    return
                }
                let chunk = try parseStreamingChunk(Data(payload.utf8))
                for delta in extractDeltas(from: chunk) {
                    continuation.yield(delta)
                }
            }
            continuation.finish()
        }
    }

    func performWithRetry<T>(
        urlRequest: URLRequest,
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
                (data, response) = try await session.data(for: urlRequest)
            } catch {
                lastError = TransportError.networkError(error)
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AgentError.llmError(.invalidResponse)
            }

            if (200 ... 299).contains(httpResponse.statusCode) {
                return try onSuccess(data, httpResponse)
            }

            let result = try await handleErrorStatus(
                httpResponse: httpResponse,
                errorBody: String(data: data, encoding: .utf8) ?? "",
                attempt: attempt,
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

    func performStreamWithRetry(
        urlRequest: URLRequest,
        onSuccess: (URLSession.AsyncBytes) async throws -> Void
    ) async throws {
        var lastError: (any Error)?
        var sleptForRetryAfter = false

        for attempt in 0 ..< retryPolicy.maxAttempts {
            try Task.checkCancellation()
            if attempt > 0, !sleptForRetryAfter {
                try await Task.sleep(for: retryPolicy.delay(forAttempt: attempt - 1))
            }
            sleptForRetryAfter = false

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: urlRequest)
            } catch {
                lastError = TransportError.networkError(error)
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AgentError.llmError(.invalidResponse)
            }

            if (200 ... 299).contains(httpResponse.statusCode) {
                try await onSuccess(bytes)
                return
            }

            let errorBody = await collectErrorBody(from: bytes)
            let result = try await handleErrorStatus(
                httpResponse: httpResponse,
                errorBody: errorBody,
                attempt: attempt,
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

    func handleErrorStatus(
        httpResponse: HTTPURLResponse,
        errorBody: String,
        attempt: Int,
        sleptForRetryAfter: inout Bool
    ) async throws -> RetryResult {
        let statusCode = httpResponse.statusCode
        guard statusCode == 429 else {
            return .stop(TransportError.httpError(statusCode: statusCode, body: errorBody))
        }
        let canRetry = attempt + 1 < retryPolicy.maxAttempts
        guard canRetry, let retryAfter = parseRetryAfter(httpResponse) else {
            return .stop(TransportError.rateLimited(retryAfter: parseRetryAfter(httpResponse)))
        }
        try await Task.sleep(for: retryAfter)
        sleptForRetryAfter = true
        return .continue
    }

    func parseRetryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(value) else { return nil }
        return .seconds(seconds)
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

    func extractDeltas(from chunk: StreamingChunk) -> [StreamDelta] {
        var deltas: [StreamDelta] = []
        for choice in chunk.choices {
            if let content = choice.delta.content, !content.isEmpty {
                deltas.append(.content(content))
            }
            if let toolCalls = choice.delta.toolCalls {
                for call in toolCalls {
                    if let id = call.id, let name = call.function?.name {
                        deltas.append(.toolCallStart(index: call.index, id: id, name: name))
                    }
                    if let args = call.function?.arguments, !args.isEmpty {
                        deltas.append(.toolCallDelta(index: call.index, arguments: args))
                    }
                }
            }
            if choice.finishReason != nil {
                deltas.append(.finished(usage: chunk.usage.map { usage in
                    let reasoning = usage.completionTokensDetails?.reasoningTokens ?? 0
                    let output = max(0, usage.completionTokens - reasoning)
                    return TokenUsage(input: usage.promptTokens, output: output, reasoning: reasoning)
                }))
            }
        }
        return deltas
    }

    func collectErrorBody(from bytes: URLSession.AsyncBytes) async -> String {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var body = ""
                var lineCount = 0
                do {
                    for try await line in bytes.lines {
                        body += line + "\n"
                        lineCount += 1
                        if lineCount >= 100 { break }
                    }
                } catch {
                    return body.isEmpty ? "(error reading body: \(error))" : body
                }
                return body
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            if let result = await group.next(), let body = result {
                group.cancelAll()
                return body
            }
            group.cancelAll()
            return "(error body read timed out)"
        }
    }
}

public extension OpenAIClient {
    static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!
    static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    static let groqBaseURL = URL(string: "https://api.groq.com/openai/v1")!
    static let togetherBaseURL = URL(string: "https://api.together.xyz/v1")!
    static let ollamaBaseURL = URL(string: "http://localhost:11434/v1")!
}
