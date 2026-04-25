import Foundation

func extractSSEPayload(from line: String) -> String? {
    guard line.hasPrefix("data:") else { return nil }
    return line.hasPrefix("data: ")
        ? String(line.dropFirst(6))
        : String(line.dropFirst(5))
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

func processSSEStream<S: AsyncSequence & Sendable>(
    bytes: S,
    stallTimeout: Duration?,
    handler: @escaping @Sendable (String) async throws -> Bool
) async throws where S.Element == UInt8 {
    if let stallTimeout {
        try await withThrowingTaskGroup(of: Void.self) { group in
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
            }

            group.addTask {
                for try await line in UnboundedLines(source: bytes) {
                    await watchdog.recordActivity()
                    if try await handler(line) { return }
                }
            }

            try await group.next()
            group.cancelAll()
        }
    } else {
        for try await line in UnboundedLines(source: bytes) {
            guard try await !handler(line) else { return }
        }
    }
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
