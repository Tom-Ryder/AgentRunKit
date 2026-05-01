@testable import AgentRunKit
import Foundation
import Testing

private func decodeRequest(_ data: Data) -> JSONRPCRequest? {
    try? JSONDecoder().decode(JSONRPCRequest.self, from: data)
}

private func standardHandler(
    toolCallHandler: (@Sendable (JSONRPCRequest) async throws -> Data?)? = nil
) -> @Sendable (Data) async throws -> Data? {
    { data in
        guard let request = decodeRequest(data) else { return nil }
        let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
        switch request.method {
        case "initialize":
            return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
        case "tools/list":
            return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.emptyToolsListResult())
        case "tools/call":
            return try await toolCallHandler?(request)
        default:
            return nil
        }
    }
}

struct MCPClientTests {
    private func makeInitAndToolsResponses(
        tools: [MCPTestHelpers.MockTool] = []
    ) -> [Data] {
        [
            MCPTestHelpers.encodeResponse(id: 1, result: MCPTestHelpers.initializeResult()),
            MCPTestHelpers.encodeResponse(id: 2, result: MCPTestHelpers.toolsListResult(tools: tools)),
        ]
    }

    @Test
    func initializeHandshake() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler())
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        let tools = await client.listTools()
        #expect(tools.isEmpty)
        await client.shutdown()
    }

    #if os(macOS)
        @Test
        func configurationInitializerPreservesServerName() {
            let client = MCPClient(configuration: MCPServerConfiguration(name: "configured", command: "/bin/test"))
            #expect(client.serverName == "configured")
        }
    #endif

    @Test
    func initializeVersionMismatch() async throws {
        let transport = ScriptedMCPTransport(responses: [
            MCPTestHelpers.encodeResponse(
                id: 1,
                result: MCPTestHelpers.initializeResult(protocolVersion: "1999-01-01")
            ),
        ])
        let client = MCPClient(serverName: "test", transport: transport)
        do {
            try await client.connectAndInitialize()
            Issue.record("Expected protocolVersionMismatch")
        } catch let error as MCPError {
            guard case let .protocolVersionMismatch(requested, supported) = error else {
                Issue.record("Expected protocolVersionMismatch, got \(error)")
                return
            }
            #expect(requested == "2025-06-18")
            #expect(supported == "1999-01-01")
        }
        await client.shutdown()
    }

    @Test
    func listToolsSinglePage() async throws {
        let schema = MCPTestHelpers.toolSchema(
            properties: ["query": .object(["type": .string("string")])],
            required: ["query"]
        )
        let transport = ScriptedMCPTransport(responses: makeInitAndToolsResponses(
            tools: [.init(name: "search", description: "Search stuff", schema: schema)]
        ))
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        let tools = await client.listTools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "search")
        #expect(tools[0].description == "Search stuff")
        await client.shutdown()
    }

    @Test
    func listToolsWithPagination() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let transport = DynamicMCPTransport { data in
            guard let request = decodeRequest(data) else { return nil }
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            switch request.method {
            case "initialize":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
            case "tools/list":
                if case let .object(params) = request.params, params["cursor"] != nil {
                    return MCPTestHelpers.encodeResponse(
                        id: idValue,
                        result: MCPTestHelpers.toolsListResult(
                            tools: [.init(name: "tool_b", description: "B", schema: schema)]
                        )
                    )
                }
                return MCPTestHelpers.encodeResponse(
                    id: idValue,
                    result: MCPTestHelpers.toolsListResult(
                        tools: [.init(name: "tool_a", description: "A", schema: schema)],
                        nextCursor: "page2"
                    )
                )
            default:
                return nil
            }
        }
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        let tools = await client.listTools()
        #expect(tools.count == 2)
        let names = tools.map(\.name)
        #expect(names.contains("tool_a"))
        #expect(names.contains("tool_b"))
        await client.shutdown()
    }

    @Test
    func callToolSuccess() async throws {
        let transport = ScriptedMCPTransport(responses: [
            MCPTestHelpers.encodeResponse(id: 1, result: MCPTestHelpers.initializeResult()),
            MCPTestHelpers.encodeResponse(id: 2, result: MCPTestHelpers.emptyToolsListResult()),
            MCPTestHelpers.encodeResponse(id: 3, result: MCPTestHelpers.callToolResult(text: "hello world")),
        ])
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        let result = try await client.callTool(name: "greet", arguments: Data("{}".utf8))
        #expect(result.content.count == 1)
        guard case let .text(text) = result.content[0] else {
            Issue.record("Expected text content")
            return
        }
        #expect(text == "hello world")
        #expect(result.isError == false)
        await client.shutdown()
    }

    @Test
    func callToolWithIsError() async throws {
        let transport = ScriptedMCPTransport(responses: [
            MCPTestHelpers.encodeResponse(id: 1, result: MCPTestHelpers.initializeResult()),
            MCPTestHelpers.encodeResponse(id: 2, result: MCPTestHelpers.emptyToolsListResult()),
            MCPTestHelpers.encodeResponse(id: 3, result: MCPTestHelpers.callToolResult(text: "fail", isError: true)),
        ])
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        let result = try await client.callTool(name: "fail_tool", arguments: Data("{}".utf8))
        #expect(result.isError == true)
        await client.shutdown()
    }

    @Test
    func callToolJsonRPCError() async throws {
        let transport = ScriptedMCPTransport(responses: [
            MCPTestHelpers.encodeResponse(id: 1, result: MCPTestHelpers.initializeResult()),
            MCPTestHelpers.encodeResponse(id: 2, result: MCPTestHelpers.emptyToolsListResult()),
            MCPTestHelpers.encodeErrorResponse(id: 3, code: -32601, message: "Method not found"),
        ])
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        do {
            _ = try await client.callTool(name: "missing", arguments: Data("{}".utf8))
            Issue.record("Expected jsonRPCError")
        } catch let error as MCPError {
            guard case let .jsonRPCError(code, message) = error else {
                Issue.record("Expected jsonRPCError, got \(error)")
                return
            }
            #expect(code == -32601)
            #expect(message == "Method not found")
        }
        await client.shutdown()
    }

    @Test
    func requestIdUniqueness() async throws {
        let idCollector = IDCollector()
        let transport = DynamicMCPTransport { data in
            guard let request = decodeRequest(data) else { return nil }
            await idCollector.add(request.id)
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            switch request.method {
            case "initialize":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
            case "tools/list":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.emptyToolsListResult())
            default:
                return nil
            }
        }
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        let ids = await idCollector.ids
        let uniqueIds = Set(ids)
        #expect(uniqueIds.count == ids.count)
        await client.shutdown()
    }

    @Test
    func concurrentCallsMatchById() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler { request in
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            guard case let .object(params) = request.params,
                  case let .string(name) = params["name"]
            else { return nil }
            try await Task.sleep(for: .milliseconds(name == "slow" ? 50 : 10))
            return MCPTestHelpers.encodeResponse(
                id: idValue,
                result: MCPTestHelpers.callToolResult(text: "result_\(name)")
            )
        })
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()

        async let slowCall = client.callTool(name: "slow", arguments: Data("{}".utf8))
        async let fastCall = client.callTool(name: "fast", arguments: Data("{}".utf8))
        let (slowResult, fastResult) = try await (slowCall, fastCall)

        guard case let .text(slowText) = slowResult.content.first else {
            Issue.record("Expected text content for slow call")
            return
        }
        guard case let .text(fastText) = fastResult.content.first else {
            Issue.record("Expected text content for fast call")
            return
        }
        #expect(slowText == "result_slow")
        #expect(fastText == "result_fast")
        await client.shutdown()
    }

    @Test
    func transportClosedMidCall() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler { _ in nil })
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()

        let callTask = Task {
            try await client.callTool(name: "test", arguments: Data("{}".utf8))
        }

        try await Task.sleep(for: .milliseconds(50))
        await transport.terminateStream()

        do {
            _ = try await callTask.value
            Issue.record("Expected transportClosed")
        } catch let error as MCPError {
            #expect(error == .transportClosed)
        }
    }

    @Test
    func requestTimeout() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler { _ in nil })
        let client = MCPClient(
            serverName: "test",
            transport: transport,
            toolCallTimeout: .milliseconds(100)
        )
        try await client.connectAndInitialize()

        do {
            _ = try await client.callTool(name: "slow", arguments: Data("{}".utf8))
            Issue.record("Expected requestTimeout")
        } catch let error as MCPError {
            guard case let .requestTimeout(method) = error else {
                Issue.record("Expected requestTimeout, got \(error)")
                return
            }
            #expect(method == "tools/call")
        }
        await client.shutdown()
    }

    @Test
    func notificationInterleaved() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler { request in
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            return MCPTestHelpers.encodeResponse(
                id: idValue,
                result: MCPTestHelpers.callToolResult(text: "result")
            )
        })
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()

        await transport.injectMessage(MCPTestHelpers.encodeNotification(method: "notifications/progress"))

        let result = try await client.callTool(name: "test", arguments: Data("{}".utf8))
        guard case let .text(text) = result.content.first else {
            Issue.record("Expected text content")
            return
        }
        #expect(text == "result")
        await client.shutdown()
    }

    @Test
    func cancellationCleanup() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler { _ in
            try await Task.sleep(for: .seconds(10))
            return nil
        })
        let client = MCPClient(
            serverName: "test",
            transport: transport,
            toolCallTimeout: .milliseconds(200)
        )
        try await client.connectAndInitialize()

        let task = Task {
            try await client.callTool(name: "test", arguments: Data("{}".utf8))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected error from cancellation or timeout")
        } catch is CancellationError {
            // expected
        } catch let error as MCPError {
            switch error {
            case .transportClosed, .requestTimeout:
                break
            default:
                Issue.record("Unexpected MCPError: \(error)")
            }
        }
        await client.shutdown()
    }

    @Test
    func shutdownResumesAllPending() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler { _ in nil })
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()

        let task = Task {
            try await client.callTool(name: "pending", arguments: Data("{}".utf8))
        }
        try await Task.sleep(for: .milliseconds(50))
        await client.shutdown()

        do {
            _ = try await task.value
            Issue.record("Expected error after shutdown")
        } catch let error as MCPError {
            #expect(error == .transportClosed)
        } catch is CancellationError {
            // expected
        }
    }

    @Test
    func callBeforeInitThrows() async throws {
        let transport = ScriptedMCPTransport(responses: [])
        let client = MCPClient(serverName: "test", transport: transport)
        do {
            _ = try await client.callTool(name: "test", arguments: Data("{}".utf8))
            Issue.record("Expected transportClosed")
        } catch let error as MCPError {
            #expect(error == .transportClosed)
        }
    }

    @Test
    func initNotificationSent() async throws {
        let dataCollector = DataCollector()
        let transport = DynamicMCPTransport { data in
            await dataCollector.add(data)
            guard let request = decodeRequest(data) else { return nil }
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            switch request.method {
            case "initialize":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
            case "tools/list":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.emptyToolsListResult())
            default:
                return nil
            }
        }
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()

        let sent = await dataCollector.items
        let hasInitNotification = sent.contains { data in
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = dict["method"] as? String
            else { return false }
            return method == "notifications/initialized" && dict["id"] == nil
        }
        #expect(hasInitNotification)
        await client.shutdown()
    }

    @Test
    func initializeRequestEmitsExpectedPayload() async throws {
        let dataCollector = DataCollector()
        let transport = DynamicMCPTransport { data in
            await dataCollector.add(data)
            guard let request = decodeRequest(data) else { return nil }
            let idValue: Int = if case let .int(value) = request.id { value } else { 0 }
            switch request.method {
            case "initialize":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
            case "tools/list":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.emptyToolsListResult())
            default:
                return nil
            }
        }
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()

        let initializeRequests = await dataCollector.items
            .compactMap(decodeRequest)
            .filter { $0.method == "initialize" }

        #expect(initializeRequests.count == 1)
        let request = try #require(initializeRequests.first)
        #expect(request.id == .int(1))

        guard case let .object(params) = request.params else {
            Issue.record("Expected initialize params")
            await client.shutdown()
            return
        }

        #expect(params["protocolVersion"] == .string("2025-06-18"))
        #expect(params["capabilities"] == .object([:]))

        guard case let .object(clientInfo) = params["clientInfo"] else {
            Issue.record("Expected clientInfo in initialize params")
            await client.shutdown()
            return
        }

        #expect(clientInfo["name"] == .string("AgentRunKit"))

        guard case let .string(version) = clientInfo["version"] else {
            Issue.record("Expected non-empty clientInfo.version in initialize params")
            await client.shutdown()
            return
        }

        #expect(!version.isEmpty)
        await client.shutdown()
    }
}

struct MCPClientEdgeCaseTests {
    @Test
    func shutdownIdempotent() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler())
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        await client.shutdown()
        await client.shutdown()

        await #expect(throws: MCPError.transportClosed) {
            try await client.callTool(name: "test", arguments: Data("{}".utf8))
        }
    }

    @Test
    func doubleInitializeThrows() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler())
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        do {
            try await client.connectAndInitialize()
            Issue.record("Expected connectionFailed on double initialize")
        } catch let error as MCPError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        }
        await client.shutdown()
    }

    @Test
    func malformedToolListMissingName() async throws {
        let transport = DynamicMCPTransport { data in
            guard let request = decodeRequest(data) else { return nil }
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            switch request.method {
            case "initialize":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
            case "tools/list":
                let malformedTools: JSONValue = .object([
                    "tools": .array([
                        .object(["description": .string("no name field")]),
                    ]),
                ])
                return MCPTestHelpers.encodeResponse(id: idValue, result: malformedTools)
            default:
                return nil
            }
        }
        let client = MCPClient(serverName: "test", transport: transport)
        do {
            try await client.connectAndInitialize()
            Issue.record("Expected DecodingError for missing name")
        } catch is DecodingError {
            // Expected: MCPToolInfo Decodable requires "name" field
        }
        await client.shutdown()
    }

    @Test
    func callToolInvalidJSONArguments() async throws {
        let transport = DynamicMCPTransport(handler: standardHandler())
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        do {
            _ = try await client.callTool(name: "test", arguments: Data("not json".utf8))
            Issue.record("Expected decoding error")
        } catch is DecodingError {
            // Expected: invalid JSON fails to decode as JSONValue
        }
        await client.shutdown()
    }
}

private actor IDCollector {
    var ids: [JSONRPCID] = []
    func add(_ id: JSONRPCID) {
        ids.append(id)
    }
}

private actor DataCollector {
    var items: [Data] = []
    func add(_ data: Data) {
        items.append(data)
    }
}
