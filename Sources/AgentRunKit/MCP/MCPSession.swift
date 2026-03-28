import Foundation

/// Coordinates multiple MCP server connections with scoped tool access.
///
/// For a guide on integrating MCP servers, see <doc:MCPIntegration>.
public struct MCPSession: Sendable {
    private let configurations: [MCPServerConfiguration]
    private let transportFactory: @Sendable (MCPServerConfiguration) -> any MCPTransport

    #if os(macOS)
        public init(configurations: [MCPServerConfiguration]) {
            self.configurations = configurations
            transportFactory = { config in
                StdioMCPTransport(
                    command: config.command,
                    arguments: config.arguments,
                    environment: config.environment,
                    workingDirectory: config.workingDirectory.map { URL(fileURLWithPath: $0) }
                )
            }
        }
    #endif

    init(
        configurations: [MCPServerConfiguration],
        transportFactory: @escaping @Sendable (MCPServerConfiguration) -> any MCPTransport
    ) {
        self.configurations = configurations
        self.transportFactory = transportFactory
    }

    /// Connects to all configured servers, discovers tools, passes them to the closure, then shuts down.
    public func withTools<C: ToolContext, R: Sendable>(
        _ body: @Sendable ([any AnyTool<C>]) async throws -> R
    ) async throws -> R {
        let clients = configurations.map { config in
            MCPClient(
                serverName: config.name,
                transport: transportFactory(config),
                initializationTimeout: config.initializationTimeout,
                toolCallTimeout: config.toolCallTimeout
            )
        }
        do {
            try await connectAll(clients)
            let tools: [any AnyTool<C>] = try await collectTools(from: clients)
            let result = try await body(tools)
            await shutdownAll(clients)
            return result
        } catch {
            await shutdownAll(clients)
            throw error
        }
    }

    private func connectAll(_ clients: [MCPClient]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask {
                    try await client.connectAndInitialize()
                }
            }
            do {
                for try await _ in group {}
            } catch {
                group.cancelAll()
                while true {
                    do {
                        guard try await group.next() != nil else { break }
                    } catch {
                        continue
                    }
                }
                throw error
            }
        }
    }

    private func collectTools<C: ToolContext>(from clients: [MCPClient]) async throws -> [any AnyTool<C>] {
        var tools: [any AnyTool<C>] = []
        var nameToServer: [String: String] = [:]

        for client in clients {
            let serverTools = await client.listTools()
            for info in serverTools {
                if let existingServer = nameToServer[info.name] {
                    throw MCPError.duplicateToolName(
                        tool: info.name,
                        servers: [existingServer, client.serverName]
                    )
                }
                nameToServer[info.name] = client.serverName
                tools.append(MCPTool<C>(info: info, client: client))
            }
        }

        return tools
    }

    private func shutdownAll(_ clients: [MCPClient]) async {
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.shutdown() }
            }
        }
    }
}
