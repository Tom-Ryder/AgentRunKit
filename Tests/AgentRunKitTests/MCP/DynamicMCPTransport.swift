@testable import AgentRunKit
import Foundation

actor DynamicMCPTransport: MCPTransport {
    private let handler: @Sendable (Data) async throws -> Data?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var effectiveDisconnectCount = 0

    init(handler: @escaping @Sendable (Data) async throws -> Data?) {
        self.handler = handler
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func connect() async throws {
        connected = true
    }

    func disconnect() async {
        if connected {
            effectiveDisconnectCount += 1
        }
        connected = false
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        guard connected else { throw MCPError.transportClosed }
        if let response = try await handler(data) {
            continuation.yield(response)
        }
    }

    nonisolated func messages() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func injectMessage(_ data: Data) {
        continuation.yield(data)
    }

    func terminateStream() {
        continuation.finish()
    }

    func terminateStreamWithError(_ error: any Error) {
        continuation.finish(throwing: error)
    }

    func effectiveDisconnectCallCount() -> Int {
        effectiveDisconnectCount
    }
}
