@testable import AgentRunKit
import Foundation
import Testing

private func makeStandardTransport(
    tools: [MCPTestHelpers.MockTool] = []
) -> DynamicMCPTransport {
    DynamicMCPTransport { data in
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else { return nil }
        let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
        switch request.method {
        case "initialize":
            return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
        case "tools/list":
            return MCPTestHelpers.encodeResponse(
                id: idValue,
                result: MCPTestHelpers.toolsListResult(tools: tools)
            )
        case "tools/call":
            guard case let .object(params) = request.params,
                  case let .string(name) = params["name"]
            else { return nil }
            return MCPTestHelpers.encodeResponse(
                id: idValue,
                result: MCPTestHelpers.callToolResult(text: "result from \(name)")
            )
        default:
            return nil
        }
    }
}

struct MCPSessionTests {
    @Test
    func singleServerLifecycle() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let session = MCPSession(configurations: [config]) { _ in
            makeStandardTransport(tools: [.init(name: "tool_a", description: "Tool A", schema: schema)])
        }

        let result: String = try await session.withTools { (tools: [any AnyTool<EmptyContext>]) in
            #expect(tools.count == 1)
            #expect(tools[0].name == "tool_a")
            return "done"
        }
        #expect(result == "done")
    }

    @Test
    func multipleServersParallel() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let configs = [
            MCPServerConfiguration(name: "server1", command: "/bin/test"),
            MCPServerConfiguration(name: "server2", command: "/bin/test2"),
        ]
        let session = MCPSession(configurations: configs) { config in
            if config.name == "server1" {
                return makeStandardTransport(tools: [.init(name: "tool_a", description: "A", schema: schema)])
            }
            return makeStandardTransport(tools: [.init(name: "tool_b", description: "B", schema: schema)])
        }

        try await session.withTools { (tools: [any AnyTool<EmptyContext>]) in
            #expect(tools.count == 2)
            let names = tools.map(\.name)
            #expect(names.contains("tool_a"))
            #expect(names.contains("tool_b"))
        }
    }

    @Test
    func duplicateToolNameThrows() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let configs = [
            MCPServerConfiguration(name: "server1", command: "/bin/test"),
            MCPServerConfiguration(name: "server2", command: "/bin/test2"),
        ]
        let session = MCPSession(configurations: configs) { _ in
            makeStandardTransport(tools: [.init(name: "same_tool", description: "Tool", schema: schema)])
        }

        do {
            try await session.withTools { (_: [any AnyTool<EmptyContext>]) in }
            Issue.record("Expected duplicateToolName error")
        } catch let error as MCPError {
            guard case let .duplicateToolName(tool, servers) = error else {
                Issue.record("Expected duplicateToolName, got \(error)")
                return
            }
            #expect(tool == "same_tool")
            #expect(servers.count == 2)
        }
    }

    @Test
    func serverFailureShutdownsOthers() async throws {
        let configs = [
            MCPServerConfiguration(name: "good", command: "/bin/test"),
            MCPServerConfiguration(name: "bad", command: "/bin/test2"),
        ]
        let session = MCPSession(configurations: configs) { config in
            if config.name == "bad" {
                return FailingTransport()
            }
            return makeStandardTransport()
        }

        do {
            try await session.withTools { (_: [any AnyTool<EmptyContext>]) in }
            Issue.record("Expected error")
        } catch let error as MCPError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        }
    }

    @Test
    func bodyErrorTriggersShutdown() async throws {
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let session = MCPSession(configurations: [config]) { _ in
            makeStandardTransport()
        }

        do {
            try await session.withTools { (_: [any AnyTool<EmptyContext>]) in
                throw TestSessionError.bodyFailed
            }
            Issue.record("Expected error")
        } catch let error as TestSessionError {
            #expect(error == .bodyFailed)
        }
    }

    @Test
    func cancellationTriggersShutdown() async throws {
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let session = MCPSession(configurations: [config]) { _ in
            makeStandardTransport()
        }

        let task = Task {
            try await session.withTools { (_: [any AnyTool<EmptyContext>]) in
                try await Task.sleep(for: .seconds(60))
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch let error as MCPError {
            #expect(error == .transportClosed)
        }
    }

    @Test
    func toolsCorrectGenericType() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let session = MCPSession(configurations: [config]) { _ in
            makeStandardTransport(tools: [.init(name: "tool_a", description: "A", schema: schema)])
        }

        try await session.withTools { (tools: [any AnyTool<EmptyContext>]) in
            #expect(tools.count == 1)
            let result = try await tools[0].execute(arguments: Data("{}".utf8), context: EmptyContext())
            #expect(result.content.contains("result from tool_a"))
        }
    }

    @Test
    func emptyConfigurations() async throws {
        let session = MCPSession(configurations: [], transportFactory: { _ in fatalError() })
        let result = try await session.withTools { (tools: [any AnyTool<EmptyContext>]) in
            tools.count
        }
        #expect(result == 0)
    }

    @Test
    func transportFactoryInjection() async throws {
        let config = MCPServerConfiguration(name: "injected", command: "/bin/test")
        let session = MCPSession(configurations: [config]) { _ in
            makeStandardTransport()
        }

        try await session.withTools { (tools: [any AnyTool<EmptyContext>]) in
            #expect(tools.isEmpty)
        }
    }
}

private enum TestSessionError: Error, Equatable {
    case bodyFailed
}

private actor FailingTransport: MCPTransport {
    private let stream: AsyncThrowingStream<Data, Error>

    init() {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.finish()
        self.stream = stream
    }

    func connect() async throws {
        throw MCPError.connectionFailed("Intentional failure")
    }

    func disconnect() async {}
    func send(_: Data) async throws {
        throw MCPError.transportClosed
    }

    nonisolated func messages() -> AsyncThrowingStream<Data, Error> {
        stream
    }
}
