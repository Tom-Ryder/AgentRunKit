import Foundation

/// Errors from MCP server communication and tool execution.
public enum MCPError: Error, Sendable, Equatable, LocalizedError {
    case connectionFailed(String)
    case protocolVersionMismatch(requested: String, supported: String)
    case jsonRPCError(code: Int, message: String)
    case requestTimeout(method: String)
    case transportClosed
    case invalidResponse(String)
    case decodingFailed(String)
    case serverStartFailed(server: String, message: String)
    case duplicateToolName(tool: String, servers: [String])

    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(desc): "MCP connection failed: \(desc)"
        case let .protocolVersionMismatch(req, sup):
            "MCP protocol version mismatch: requested \(req), server supports \(sup)"
        case let .jsonRPCError(code, msg): "MCP JSON-RPC error \(code): \(msg)"
        case let .requestTimeout(method): "MCP request timed out: \(method)"
        case .transportClosed: "MCP transport closed"
        case let .invalidResponse(desc): "MCP invalid response: \(desc)"
        case let .decodingFailed(desc): "MCP decoding failed: \(desc)"
        case let .serverStartFailed(server, msg): "MCP server '\(server)' failed to start: \(msg)"
        case let .duplicateToolName(tool, servers):
            "MCP duplicate tool '\(tool)' across: \(servers.joined(separator: ", "))"
        }
    }
}
