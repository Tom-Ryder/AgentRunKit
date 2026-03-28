import Foundation

/// A bidirectional communication channel for MCP JSON-RPC messages.
public protocol MCPTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func messages() -> AsyncThrowingStream<Data, Error>
}
