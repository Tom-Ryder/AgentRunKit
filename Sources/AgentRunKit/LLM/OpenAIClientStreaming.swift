import Foundation

extension OpenAIClient {
    enum RetryResult {
        case `continue`
        case stop(any Error)
    }

    func performStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        let request = buildRequest(messages: messages, tools: tools, stream: true, extraFields: extraFields)
        let urlRequest = try buildURLRequest(request)

        try await performStreamWithRetry(urlRequest: urlRequest, onResponse: onResponse) { bytes in
            for try await line in UnboundedLines(source: bytes) {
                try Task.checkCancellation()
                guard let payload = Self.extractSSEPayload(from: line) else { continue }
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
                (data, response) = try await session.data(for: urlRequest)
            } catch {
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
        onResponse: (@Sendable (HTTPURLResponse) -> Void)? = nil,
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
                onResponse?(httpResponse)
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
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Int(value) {
            return .seconds(seconds)
        }
        if let date = Self.parseHTTPDate(value) {
            let seconds = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
            return .seconds(seconds)
        }
        return nil
    }

    private static let httpDateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }

    private static func parseHTTPDate(_ string: String) -> Date? {
        for formatter in httpDateFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    static func extractSSEPayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return line.hasPrefix("data: ")
            ? String(line.dropFirst(6))
            : String(line.dropFirst(5))
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
            if let reasoning = choice.delta.reasoning ?? choice.delta.reasoningContent, !reasoning.isEmpty {
                deltas.append(.reasoning(reasoning))
            }
            if let content = choice.delta.content, !content.isEmpty {
                deltas.append(.content(content))
            }
            if let toolCalls = choice.delta.toolCalls {
                for call in toolCalls {
                    if let id = call.id, !id.isEmpty, let name = call.function?.name, !name.isEmpty {
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

struct UnboundedLines<Source: AsyncSequence>: AsyncSequence where Source.Element == UInt8 {
    typealias Element = String
    let source: Source

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(sourceIterator: source.makeAsyncIterator())
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var sourceIterator: Source.AsyncIterator
        var buffer = Data(capacity: 4096)

        mutating func next() async throws -> String? {
            while true {
                guard let byte = try await sourceIterator.next() else {
                    if buffer.isEmpty { return nil }
                    return try decodeAndClear()
                }
                if byte == 0x0A {
                    return try decodeAndClear()
                }
                buffer.append(byte)
            }
        }

        private mutating func decodeAndClear() throws -> String {
            defer { buffer.removeAll(keepingCapacity: true) }
            if buffer.last == 0x0D { buffer.removeLast() }
            guard let line = String(data: buffer, encoding: .utf8) else {
                throw AgentError.llmError(.decodingFailed(description: "Invalid UTF-8 in SSE stream"))
            }
            return line
        }
    }
}
