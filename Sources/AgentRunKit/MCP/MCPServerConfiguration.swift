import Foundation

/// Configuration for launching and connecting to an MCP server.
public struct MCPServerConfiguration: Sendable, Equatable {
    public let name: String
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: String?
    public let initializationTimeout: Duration
    public let toolCallTimeout: Duration

    public init(
        name: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        initializationTimeout: Duration = .seconds(30),
        toolCallTimeout: Duration = .seconds(60)
    ) {
        precondition(!name.isEmpty, "MCPServerConfiguration name must not be empty")
        precondition(!command.isEmpty, "MCPServerConfiguration command must not be empty")
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.initializationTimeout = initializationTimeout
        self.toolCallTimeout = toolCallTimeout
    }
}
