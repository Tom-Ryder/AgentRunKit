import Foundation

enum HTTPRetry {
    enum RetryResult {
        case `continue`
        case stop(any Error)
    }

    static func performData(
        urlRequest: URLRequest,
        session: URLSession,
        retryPolicy: RetryPolicy
    ) async throws -> (Data, HTTPURLResponse) {
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
                return (data, httpResponse)
            }

            let result = try await handleErrorStatus(
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

    static func performStream(
        urlRequest: URLRequest,
        session: URLSession,
        retryPolicy: RetryPolicy
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
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
                return (bytes, httpResponse)
            }

            let errorBody = await collectErrorBody(from: bytes)
            let result = try await handleErrorStatus(
                httpResponse: httpResponse,
                errorBody: errorBody,
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

    static func handleErrorStatus(
        httpResponse: HTTPURLResponse,
        errorBody: String,
        attempt: Int,
        retryPolicy: RetryPolicy,
        sleptForRetryAfter: inout Bool
    ) async throws -> RetryResult {
        let statusCode = httpResponse.statusCode
        guard statusCode == 429 else {
            return .stop(TransportError.httpError(statusCode: statusCode, body: errorBody))
        }
        let canRetry = attempt + 1 < retryPolicy.maxAttempts
        let retryAfter = parseRetryAfter(httpResponse)
        guard canRetry, let retryAfter else {
            return .stop(TransportError.rateLimited(retryAfter: retryAfter))
        }
        try await Task.sleep(for: retryAfter)
        sleptForRetryAfter = true
        return .continue
    }

    static func parseRetryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Int(value) {
            return .seconds(seconds)
        }
        if let date = parseHTTPDate(value) {
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

    static func parseHTTPDate(_ string: String) -> Date? {
        for formatter in httpDateFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    static func collectErrorBody(from bytes: URLSession.AsyncBytes) async -> String {
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
