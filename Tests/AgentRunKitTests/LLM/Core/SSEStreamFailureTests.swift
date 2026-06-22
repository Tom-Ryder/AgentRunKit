@testable import AgentRunKit
import Foundation
import Testing

struct DelayedByteStream<C: Clock>: AsyncSequence where C.Duration == Duration {
    typealias Element = UInt8
    let clock: C
    let chunks: [Chunk]

    struct Chunk {
        let delay: Duration
        let bytes: [UInt8]
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(clock: clock, chunks: chunks)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let clock: C
        let chunks: [Chunk]
        var chunkIndex = 0
        var byteIndex = 0

        mutating func next() async throws -> UInt8? {
            guard chunkIndex < chunks.count else { return nil }
            let chunk = chunks[chunkIndex]
            if byteIndex == 0, chunk.delay > .zero {
                try await clock.sleep(for: chunk.delay)
            }
            guard byteIndex < chunk.bytes.count else {
                chunkIndex += 1
                byteIndex = 0
                return try await next()
            }
            defer {
                byteIndex += 1
                if byteIndex == chunk.bytes.count {
                    chunkIndex += 1
                    byteIndex = 0
                }
            }
            return chunk.bytes[byteIndex]
        }
    }
}

extension DelayedByteStream where C == ContinuousClock {
    init(chunks: [Chunk]) {
        self.init(clock: ContinuousClock(), chunks: chunks)
    }
}

struct ThrowingByteStream: AsyncSequence {
    typealias Element = UInt8
    let bytes: [UInt8]
    let error: URLError

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes, error: error)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let bytes: [UInt8]
        let error: URLError
        var index = 0

        mutating func next() async throws -> UInt8? {
            guard index < bytes.count else {
                throw error
            }
            defer { index += 1 }
            return bytes[index]
        }
    }
}

struct SSEStreamFailureTests {
    private func sseChunk(_ json: String) -> [UInt8] {
        Array("data: \(json)\n\n".utf8)
    }

    private func sseDone() -> [UInt8] {
        Array("data: [DONE]\n\n".utf8)
    }

    private func sseComment(_ text: String) -> [UInt8] {
        Array(": \(text)\n\n".utf8)
    }

    private let minimalChunkJSON = """
    {"choices":[{"delta":{"content":"hello"},"index":0}]}
    """

    @Test
    func commentHeartbeatsRefreshStallDeadlineWithoutIncrementingEventDiagnostics() async throws {
        let clock = TestClock()
        let bytes = DelayedByteStream(clock: clock, chunks: [
            .init(delay: .zero, bytes: sseChunk(minimalChunkJSON)),
            .init(delay: .seconds(1), bytes: sseComment("keepalive")),
            .init(delay: .seconds(1), bytes: sseComment("keepalive")),
            .init(delay: .seconds(1), bytes: sseDone()),
        ])

        let task = Task {
            try await processSSEStream(
                bytes: bytes,
                provider: .custom("test"),
                stallTimeout: .milliseconds(2500),
                clock: clock
            ) { event, _ in
                event.data == "[DONE]" ? .complete : .continue
            }
        }

        await clock.awaitSuspensions(atLeast: 2)
        clock.advance(by: .seconds(1))
        await clock.awaitSuspensions(atLeast: 2)
        clock.advance(by: .seconds(1))
        await clock.awaitSuspensions(atLeast: 2)
        clock.advance(by: .seconds(1))
        let completion = try await task.value

        #expect(completion.terminalMarkerSeen)
        #expect(completion.diagnostics.eventsObserved == 2)
        #expect(completion.diagnostics.lastEvent == nil)
    }

    @Test
    func completeOnEOFPersistsAcrossLaterEventsAndCompletesAtEOF() async throws {
        let bytes = DelayedByteStream(chunks: [
            .init(delay: .zero, bytes: sseChunk("finish")),
            .init(delay: .zero, bytes: sseChunk("tail")),
        ])

        let completion = try await processSSEStream(
            bytes: bytes,
            provider: .openRouter,
            stallTimeout: nil
        ) { event, _ in
            event.data == "finish" ? .completeOnEOF : .continue
        }

        #expect(!completion.terminalMarkerSeen)
        #expect(completion.diagnostics.finishSignalSeen)
        #expect(completion.diagnostics.provider == .openRouter)
        #expect(completion.diagnostics.eventsObserved == 2)
    }

    @Test
    func completeOnEOFFromFinalFlushedEventCompletesAtEOF() async throws {
        let bytes = DelayedByteStream(chunks: [
            .init(delay: .zero, bytes: Array("data: finish".utf8)),
        ])

        let completion = try await processSSEStream(
            bytes: bytes,
            provider: .custom("test"),
            stallTimeout: nil
        ) { event, _ in
            event.data == "finish" ? .completeOnEOF : .continue
        }

        #expect(!completion.terminalMarkerSeen)
        #expect(completion.diagnostics.finishSignalSeen)
        #expect(completion.diagnostics.eventsObserved == 1)
    }

    @Test
    func completeFromFinalFlushedEventReportsTerminalMarker() async throws {
        let bytes = DelayedByteStream(chunks: [
            .init(delay: .zero, bytes: Array("data: [DONE]".utf8)),
        ])

        let completion = try await processSSEStream(
            bytes: bytes,
            provider: .custom("test"),
            stallTimeout: nil
        ) { event, _ in
            event.data == "[DONE]" ? .complete : .continue
        }

        #expect(completion.terminalMarkerSeen)
        #expect(completion.diagnostics.eventsObserved == 1)
    }

    @Test
    func emptyStreamThrowsProviderTerminationMissingWithZeroEvents() async throws {
        let bytes = DelayedByteStream(chunks: [])

        do {
            try await processSSEStream(
                bytes: bytes,
                provider: .custom("test"),
                stallTimeout: nil
            ) { _, _ in .continue }
            Issue.record("Expected provider termination missing")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.providerTerminationMissing(diagnostics))) = error else {
                Issue.record("Expected provider termination missing, got \(error)")
                return
            }
            #expect(diagnostics.eventsObserved == 0)
            #expect(!diagnostics.finishSignalSeen)
        }
    }

    @Test
    func stallAfterFinishSignalThrowsIdleTimeoutWithFinishSignalSeen() async throws {
        let clock = TestClock()
        let bytes = DelayedByteStream(clock: clock, chunks: [
            .init(delay: .zero, bytes: sseChunk("finish")),
            .init(delay: .seconds(10), bytes: sseChunk("tail")),
        ])

        let task = Task {
            try await processSSEStream(
                bytes: bytes,
                provider: .custom("test"),
                stallTimeout: .seconds(3),
                clock: clock
            ) { event, _ in
                event.data == "finish" ? .completeOnEOF : .continue
            }
        }

        await clock.awaitSuspensions(atLeast: 2)
        clock.advance(by: .seconds(3))

        do {
            _ = try await task.value
            Issue.record("Expected idle timeout")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.idleTimeout(diagnostics))) = error else {
                Issue.record("Expected idle timeout, got \(error)")
                return
            }
            #expect(diagnostics.finishSignalSeen)
            #expect(diagnostics.eventsObserved == 1)
        }
    }

    @Test
    func transportFailureAfterFinishSignalCarriesFinishSignalSeen() async throws {
        let bytes = ThrowingByteStream(
            bytes: sseChunk("finish"),
            error: URLError(.networkConnectionLost)
        )

        do {
            try await processSSEStream(
                bytes: bytes,
                provider: .custom("test"),
                stallTimeout: nil
            ) { event, _ in
                event.data == "finish" ? .completeOnEOF : .continue
            }
            Issue.record("Expected transport failure")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.midStreamTransportFailure(code, diagnostics))) = error else {
                Issue.record("Expected transport failure, got \(error)")
                return
            }
            #expect(code == .networkConnectionLost)
            #expect(diagnostics.finishSignalSeen)
        }
    }

    @Test
    func midStreamURLErrorBecomesTypedTransportFailure() async throws {
        let urlError = URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLErrorKey: URL(string: "https://api.example.test?api_key=secret-token") as Any,
                NSLocalizedDescriptionKey: "api_key=secret-token"
            ]
        )
        let bytes = ThrowingByteStream(bytes: sseChunk(minimalChunkJSON), error: urlError)

        do {
            try await processSSEStream(
                bytes: bytes,
                provider: .custom("test"),
                stallTimeout: .seconds(5)
            ) { _, _ in .continue }
            Issue.record("Expected mid-stream transport failure")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .streamFailed(.midStreamTransportFailure(code, diagnostics)) = transport
            else {
                Issue.record("Expected mid-stream transport failure, got \(error)")
                return
            }
            #expect(code == .timedOut)
            #expect(diagnostics.eventsObserved == 1)
            #expect(!transport.description.contains("secret-token"))
            #expect(!String(reflecting: transport).contains("secret-token"))
        }
    }
}
