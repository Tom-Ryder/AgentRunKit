import Foundation

struct SSEEvent: Equatable {
    let event: String?
    let data: String
    let id: String?
    let retry: Int?
}

struct SSEEventParser {
    private var event: String?
    private var dataLines: [String] = []
    private var id: String?
    private var retry: Int?
    private var hasData = false

    mutating func appendLine(_ line: String) -> SSEEvent? {
        guard !line.isEmpty else {
            return flush()
        }
        guard !line.hasPrefix(":") else {
            return nil
        }

        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var remainder = String(line[line.index(after: colon)...])
            if remainder.first == " " {
                remainder.removeFirst()
            }
            value = remainder
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            event = value
        case "data":
            dataLines.append(value)
            hasData = true
        case "id":
            id = value
        case "retry":
            retry = Int(value)
        default:
            break
        }
        return nil
    }

    mutating func finish() -> SSEEvent? {
        flush()
    }

    private mutating func flush() -> SSEEvent? {
        defer {
            event = nil
            dataLines.removeAll(keepingCapacity: true)
            id = nil
            retry = nil
            hasData = false
        }
        guard hasData else { return nil }
        return SSEEvent(event: event, data: dataLines.joined(separator: "\n"), id: id, retry: retry)
    }
}

func buildJSONPostRequest(
    url: URL,
    body: some Encodable,
    headers: [String: String]
) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (field, value) in headers {
        request.setValue(value, forHTTPHeaderField: field)
    }
    do {
        request.httpBody = try JSONEncoder().encode(body)
    } catch {
        throw AgentError.llmError(.encodingFailed(error))
    }
    return request
}

@discardableResult
func processSSEStream<S: AsyncSequence & Sendable>(
    bytes: S,
    stallTimeout: Duration?,
    handler: @escaping @Sendable (SSEEvent, StreamFailureDiagnostics) async throws -> Bool
) async throws -> StreamFailureDiagnostics where S.Element == UInt8 {
    let progress = StreamProgress()
    let started = ContinuousClock.now

    if let stallTimeout {
        return try await withThrowingTaskGroup(of: StreamFailureDiagnostics.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    let lastActivity = await progress.lastActivity
                    let elapsed = ContinuousClock.now - lastActivity
                    if elapsed >= stallTimeout {
                        let diagnostics = await progress.snapshot(elapsed: ContinuousClock.now - started)
                        throw AgentError.llmError(.streamFailed(.idleTimeout(
                            diagnostics: diagnostics
                        )))
                    }
                    try await Task.sleep(for: stallTimeout - elapsed)
                }
            }

            group.addTask {
                try await runSSEParser(bytes: bytes, progress: progress, started: started, handler: handler)
            }

            guard let result = try await group.next() else {
                let diagnostics = await progress.snapshot(elapsed: ContinuousClock.now - started)
                throw AgentError.llmError(.streamFailed(.providerTerminationMissing(
                    diagnostics: diagnostics
                )))
            }
            return result
        }
    }

    return try await runSSEParser(bytes: bytes, progress: progress, started: started, handler: handler)
}

private func runSSEParser<S: AsyncSequence & Sendable>(
    bytes: S,
    progress: StreamProgress,
    started: ContinuousClock.Instant,
    handler: @Sendable (SSEEvent, StreamFailureDiagnostics) async throws -> Bool
) async throws -> StreamFailureDiagnostics where S.Element == UInt8 {
    var parser = SSEEventParser()
    do {
        for try await line in UnboundedLines(source: bytes) {
            await progress.recordActivity()
            guard let event = parser.appendLine(line) else { continue }
            await progress.recordEvent(eventName: event.event)
            let diagnostics = await progress.snapshot(elapsed: ContinuousClock.now - started)
            if try await handler(event, diagnostics) {
                return diagnostics
            }
        }
        if let event = parser.finish() {
            await progress.recordEvent(eventName: event.event)
            let diagnostics = await progress.snapshot(elapsed: ContinuousClock.now - started)
            if try await handler(event, diagnostics) {
                return diagnostics
            }
        }
        try Task.checkCancellation()
        let diagnostics = await progress.snapshot(elapsed: ContinuousClock.now - started)
        throw AgentError.llmError(.streamFailed(.providerTerminationMissing(
            diagnostics: diagnostics
        )))
    } catch is CancellationError {
        throw CancellationError()
    } catch let urlError as URLError {
        let diagnostics = await progress.snapshot(elapsed: ContinuousClock.now - started)
        throw AgentError.llmError(.streamFailed(.midStreamTransportFailure(
            code: urlError.code,
            diagnostics: diagnostics
        )))
    }
}

actor StreamProgress {
    private(set) var lastActivity: ContinuousClock.Instant = .now
    private var eventsObserved: Int = 0
    private var lastEvent: String?

    func recordActivity() {
        lastActivity = .now
    }

    func recordEvent(eventName: String?) {
        lastActivity = .now
        eventsObserved += 1
        if let eventName, !eventName.isEmpty {
            lastEvent = eventName
        }
    }

    func snapshot(elapsed: Duration) -> StreamFailureDiagnostics {
        StreamFailureDiagnostics(elapsed: elapsed, eventsObserved: eventsObserved, lastEvent: lastEvent)
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
