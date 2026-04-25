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
    handler: @escaping @Sendable (SSEEvent) async throws -> Bool
) async throws -> Bool where S.Element == UInt8 {
    if let stallTimeout {
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            let watchdog = StallWatchdog()

            group.addTask {
                while !Task.isCancelled {
                    let snapshot = await watchdog.lastActivity
                    try await Task.sleep(for: stallTimeout)
                    let current = await watchdog.lastActivity
                    if current == snapshot {
                        throw AgentError.llmError(.streamStalled)
                    }
                }
                return false
            }

            group.addTask {
                var parser = SSEEventParser()
                for try await line in UnboundedLines(source: bytes) {
                    await watchdog.recordActivity()
                    if let event = parser.appendLine(line),
                       try await handler(event) {
                        return true
                    }
                }
                if let event = parser.finish() {
                    return try await handler(event)
                }
                return false
            }

            let completed = try await group.next() ?? false
            group.cancelAll()
            return completed
        }
    }
    var parser = SSEEventParser()
    for try await line in UnboundedLines(source: bytes) {
        guard let event = parser.appendLine(line) else { continue }
        guard try await !handler(event) else {
            return true
        }
    }
    if let event = parser.finish() {
        return try await handler(event)
    }
    return false
}

actor StallWatchdog {
    private(set) var lastActivity: ContinuousClock.Instant = .now

    func recordActivity() {
        lastActivity = .now
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
