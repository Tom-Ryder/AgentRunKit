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

enum SSEDisposition {
    case `continue`
    case complete
    case completeOnEOF
}

struct SSECompletion {
    let diagnostics: StreamFailureDiagnostics
    let terminalMarkerSeen: Bool
}

@discardableResult
func processSSEStream<S: AsyncSequence & Sendable, C: Clock>(
    bytes: S,
    provider: ProviderIdentifier,
    stallTimeout: Duration?,
    clock: C = ContinuousClock(),
    handler: @escaping @Sendable (SSEEvent, StreamFailureDiagnostics) async throws -> SSEDisposition
) async throws -> SSECompletion where S.Element == UInt8, C.Duration == Duration {
    let progress = StreamProgress(provider: provider)
    let started = clock.now

    if let stallTimeout {
        return try await withThrowingTaskGroup(of: SSECompletion.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    let lastActivityOffset = await progress.lastActivityOffset
                    let deadline = started.advanced(by: lastActivityOffset + stallTimeout)
                    if clock.now >= deadline {
                        let diagnostics = await progress.snapshot(elapsed: started.duration(to: clock.now))
                        throw AgentError.llmError(.streamFailed(.idleTimeout(
                            diagnostics: diagnostics
                        )))
                    }
                    try await clock.sleep(until: deadline, tolerance: nil)
                }
            }

            group.addTask {
                try await runSSEParser(
                    bytes: bytes, progress: progress, started: started, clock: clock, handler: handler
                )
            }

            guard let result = try await group.next() else {
                preconditionFailure("Stream task group completed without a result")
            }
            return result
        }
    }

    return try await runSSEParser(bytes: bytes, progress: progress, started: started, clock: clock, handler: handler)
}

private func runSSEParser<S: AsyncSequence & Sendable, C: Clock>(
    bytes: S,
    progress: StreamProgress,
    started: C.Instant,
    clock: C,
    handler: @Sendable (SSEEvent, StreamFailureDiagnostics) async throws -> SSEDisposition
) async throws -> SSECompletion where S.Element == UInt8, C.Duration == Duration {
    func dispatch(_ event: SSEEvent) async throws -> SSECompletion? {
        await progress.recordEvent(eventName: event.event, offset: started.duration(to: clock.now))
        let diagnostics = await progress.snapshot(elapsed: started.duration(to: clock.now))
        switch try await handler(event, diagnostics) {
        case .continue:
            return nil
        case .complete:
            return SSECompletion(diagnostics: diagnostics, terminalMarkerSeen: true)
        case .completeOnEOF:
            await progress.recordFinishSignal()
            return nil
        }
    }

    var parser = SSEEventParser()
    do {
        for try await line in UnboundedLines(source: bytes) {
            await progress.recordActivity(offset: started.duration(to: clock.now))
            guard let event = parser.appendLine(line) else { continue }
            if let completion = try await dispatch(event) {
                return completion
            }
        }
        if let event = parser.finish(), let completion = try await dispatch(event) {
            return completion
        }
        try Task.checkCancellation()
        let diagnostics = await progress.snapshot(elapsed: started.duration(to: clock.now))
        guard diagnostics.finishSignalSeen else {
            throw AgentError.llmError(.streamFailed(.providerTerminationMissing(
                diagnostics: diagnostics
            )))
        }
        return SSECompletion(diagnostics: diagnostics, terminalMarkerSeen: false)
    } catch is CancellationError {
        throw CancellationError()
    } catch let urlError as URLError {
        let diagnostics = await progress.snapshot(elapsed: started.duration(to: clock.now))
        throw AgentError.llmError(.streamFailed(.midStreamTransportFailure(
            code: urlError.code,
            diagnostics: diagnostics
        )))
    }
}

actor StreamProgress {
    private let provider: ProviderIdentifier
    private(set) var lastActivityOffset: Duration = .zero
    private var eventsObserved: Int = 0
    private var lastEvent: String?
    private var finishSignalSeen = false

    init(provider: ProviderIdentifier) {
        self.provider = provider
    }

    func recordActivity(offset: Duration) {
        lastActivityOffset = offset
    }

    func recordEvent(eventName: String?, offset: Duration) {
        lastActivityOffset = offset
        eventsObserved += 1
        if let eventName, !eventName.isEmpty {
            lastEvent = eventName
        }
    }

    func recordFinishSignal() {
        finishSignalSeen = true
    }

    func snapshot(elapsed: Duration) -> StreamFailureDiagnostics {
        StreamFailureDiagnostics(
            provider: provider,
            elapsed: elapsed,
            eventsObserved: eventsObserved,
            finishSignalSeen: finishSignalSeen,
            lastEvent: lastEvent
        )
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
