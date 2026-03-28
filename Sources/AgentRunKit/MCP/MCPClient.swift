import Foundation

private enum MCPConstants {
    static let protocolVersion = "2025-06-18"
    static let clientName = "AgentRunKit"
    static let clientVersion = "1.20.1"
}

private struct MCPInitializeResult: Decodable {
    let protocolVersion: String
}

private struct MCPToolsListResult: Decodable {
    let tools: [MCPToolInfo]
    let nextCursor: String?
}

/// Manages a connection to a single MCP server.
///
/// For a guide on integrating MCP servers, see <doc:MCPIntegration>.
public actor MCPClient {
    enum State {
        case created
        case connecting
        case ready
        case disconnected
        case failed(MCPError)
    }

    public nonisolated let serverName: String
    private let transport: any MCPTransport
    private let initializationTimeout: Duration
    private let toolCallTimeout: Duration

    private var state: State = .created
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var discoveredTools: [MCPToolInfo] = []
    private var readerTask: Task<Void, Never>?

    public init(
        serverName: String,
        transport: any MCPTransport,
        initializationTimeout: Duration = .seconds(30),
        toolCallTimeout: Duration = .seconds(60)
    ) {
        self.serverName = serverName
        self.transport = transport
        self.initializationTimeout = initializationTimeout
        self.toolCallTimeout = toolCallTimeout
    }

    #if os(macOS)
        public init(configuration: MCPServerConfiguration) {
            self.init(
                serverName: configuration.name,
                transport: StdioMCPTransport(
                    command: configuration.command,
                    arguments: configuration.arguments,
                    environment: configuration.environment,
                    workingDirectory: configuration.workingDirectory.map { URL(fileURLWithPath: $0) }
                ),
                initializationTimeout: configuration.initializationTimeout,
                toolCallTimeout: configuration.toolCallTimeout
            )
        }
    #endif

    func connectAndInitialize() async throws {
        guard case .created = state else {
            throw MCPError.connectionFailed("MCPClient is in state \(state), expected .created")
        }
        state = .connecting

        do {
            try await transport.connect()
        } catch {
            state = .failed(.connectionFailed(String(describing: error)))
            throw MCPError.connectionFailed(String(describing: error))
        }

        guard case .connecting = state else { throw MCPError.transportClosed }

        startReaderTask()

        guard case .connecting = state else { throw MCPError.transportClosed }

        let initResult = try await sendRequest(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPConstants.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string(MCPConstants.clientName),
                    "version": .string(MCPConstants.clientVersion)
                ])
            ]),
            timeout: initializationTimeout
        )

        guard case .connecting = state else { throw MCPError.transportClosed }

        let initResponse: MCPInitializeResult
        do {
            initResponse = try initResult.decodeResult(as: MCPInitializeResult.self)
        } catch {
            let err = MCPError.invalidResponse("Missing protocolVersion in initialize response")
            state = .failed(err)
            throw err
        }

        if initResponse.protocolVersion != MCPConstants.protocolVersion {
            let err = MCPError.protocolVersionMismatch(
                requested: MCPConstants.protocolVersion, supported: initResponse.protocolVersion
            )
            state = .failed(err)
            throw err
        }

        try await transport.send(
            JSONEncoder().encode(JSONRPCNotification(method: "notifications/initialized"))
        )

        guard case .connecting = state else { throw MCPError.transportClosed }

        discoveredTools = try await fetchAllTools()

        guard case .connecting = state else { throw MCPError.transportClosed }

        state = .ready
    }

    func listTools() -> [MCPToolInfo] {
        discoveredTools
    }

    func callTool(name: String, arguments: Data) async throws -> MCPCallResult {
        guard case .ready = state else {
            throw MCPError.transportClosed
        }

        let argumentsValue: JSONValue = if arguments.isEmpty || String(data: arguments, encoding: .utf8) == "{}" {
            .object([:])
        } else {
            try JSONDecoder().decode(JSONValue.self, from: arguments)
        }

        let response = try await sendRequest(
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": argumentsValue
            ]),
            timeout: toolCallTimeout
        )

        guard case .ready = state else { throw MCPError.transportClosed }

        if let error = response.error {
            throw MCPError.jsonRPCError(code: error.code, message: error.message)
        }

        return try response.decodeResult(as: MCPCallResult.self)
    }

    func shutdown() async {
        guard drainPendingRequests() else { return }
        readerTask?.cancel()
        readerTask = nil
        await transport.disconnect()
    }

    private func sendRequest(
        method: String,
        params: JSONValue?,
        timeout: Duration
    ) async throws -> JSONRPCResponse {
        let id = nextRequestId
        nextRequestId += 1

        let request = JSONRPCRequest(id: .int(id), method: method, params: params)
        let data = try JSONEncoder().encode(request)

        // Register continuation BEFORE sending to prevent the actor reentrancy race
        // where a fast response arrives before registration.
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            Task {
                do {
                    try await self.transport.send(data)
                } catch {
                    self.failRequest(id: id, error: error)
                }
            }

            timeoutTasks[id] = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                self.expireRequest(id: id, method: method)
            }
        }
    }

    private func expireRequest(id: Int, method: String) {
        timeoutTasks.removeValue(forKey: id)
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: MCPError.requestTimeout(method: method))
        }
    }

    private func failRequest(id: Int, error: any Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func startReaderTask() {
        readerTask = Task { [weak self] in
            guard let self else { return }
            let stream = transport.messages()
            do {
                for try await data in stream {
                    await handleMessage(data)
                }
            } catch {}
            await handleTransportClosed()
        }
    }

    private func handleMessage(_ data: Data) {
        let message: JSONRPCMessage
        do {
            message = try JSONDecoder().decode(JSONRPCMessage.self, from: data)
        } catch {
            // MCP protocol resilience: malformed messages are ignored so the reader
            // continues processing subsequent valid messages on the same transport.
            return
        }

        switch message {
        case let .response(response):
            guard let responseId = response.id else { return }
            guard case let .int(id) = responseId else { return }
            if let continuation = pendingRequests.removeValue(forKey: id) {
                timeoutTasks.removeValue(forKey: id)?.cancel()
                continuation.resume(returning: response)
            }
        case .request, .notification:
            break
        }
    }

    private func handleTransportClosed() {
        _ = drainPendingRequests()
    }

    @discardableResult
    private func drainPendingRequests() -> Bool {
        switch state {
        case .disconnected, .failed:
            return false
        default:
            break
        }
        state = .disconnected
        let timeouts = timeoutTasks
        timeoutTasks.removeAll()
        for (_, task) in timeouts {
            task.cancel()
        }
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.transportClosed)
        }
        return true
    }

    private func fetchAllTools() async throws -> [MCPToolInfo] {
        var allTools: [MCPToolInfo] = []
        var cursor: String?

        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }

            let response = try await sendRequest(
                method: "tools/list",
                params: params.isEmpty ? nil : .object(params),
                timeout: initializationTimeout
            )

            let page = try response.decodeResult(as: MCPToolsListResult.self)
            allTools.append(contentsOf: page.tools)
            cursor = page.nextCursor
        } while cursor != nil

        return allTools
    }
}
