@testable import AgentRunKit
import Foundation
import Testing

struct DelayedByteStream: AsyncSequence {
    typealias Element = UInt8
    let chunks: [Chunk]

    struct Chunk {
        let delay: Duration
        let bytes: [UInt8]
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let chunks: [Chunk]
        var chunkIndex = 0
        var byteIndex = 0

        mutating func next() async throws -> UInt8? {
            guard chunkIndex < chunks.count else { return nil }
            let chunk = chunks[chunkIndex]
            if byteIndex == 0, chunk.delay > .zero {
                try await Task.sleep(for: chunk.delay)
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
        let bytes = DelayedByteStream(chunks: [
            .init(delay: .zero, bytes: sseChunk(minimalChunkJSON)),
            .init(delay: .milliseconds(60), bytes: sseComment("keepalive")),
            .init(delay: .milliseconds(60), bytes: sseComment("keepalive")),
            .init(delay: .milliseconds(60), bytes: sseDone()),
        ])

        let diagnostics = try await processSSEStream(
            bytes: bytes,
            stallTimeout: .milliseconds(100)
        ) { event, _ in
            event.data == "[DONE]"
        }

        #expect(diagnostics.eventsObserved == 2)
        #expect(diagnostics.lastEvent == nil)
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
                stallTimeout: .seconds(5)
            ) { _, _ in false }
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
