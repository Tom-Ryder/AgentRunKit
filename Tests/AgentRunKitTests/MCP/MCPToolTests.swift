@testable import AgentRunKit
import Foundation
import Testing

struct MCPToolTests {
    private func makeReadyClient(
        toolCallHandler: (@Sendable (String, Data) async throws -> MCPCallResult)? = nil
    ) async throws -> MCPClient {
        let transport = DynamicMCPTransport { data in
            guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else { return nil }
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            switch request.method {
            case "initialize":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
            case "tools/list":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.emptyToolsListResult())
            case "tools/call":
                guard case let .object(params) = request.params,
                      case let .string(name) = params["name"]
                else { return nil }
                if let handler = toolCallHandler {
                    let argsValue = params["arguments"]
                    let argsData = if let argsValue { try JSONEncoder().encode(argsValue) } else { Data("{}".utf8) }
                    let result = try await handler(name, argsData)
                    return MCPTestHelpers.encodeResponse(
                        id: idValue,
                        result: callResultToJSONValue(result)
                    )
                }
                return MCPTestHelpers.encodeResponse(
                    id: idValue,
                    result: MCPTestHelpers.callToolResult(text: "default response")
                )
            default:
                return nil
            }
        }
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        return client
    }

    @Test
    func namePassthrough() async throws {
        let client = try await makeReadyClient()
        let info = MCPToolInfo(
            name: "my_tool",
            description: "Does stuff",
            inputSchema: .object(properties: [:], required: [])
        )
        let tool = MCPTool<EmptyContext>(info: info, client: client)
        #expect(tool.name == "my_tool")
        await client.shutdown()
    }

    @Test
    func schemaPassthrough() async throws {
        let client = try await makeReadyClient()
        let schema = JSONSchema.object(properties: ["x": .string()], required: ["x"])
        let info = MCPToolInfo(name: "test", description: "Test", inputSchema: schema)
        let tool = MCPTool<EmptyContext>(info: info, client: client)
        #expect(tool.parametersSchema == schema)
        await client.shutdown()
    }

    @Test
    func executeForwardsToClient() async throws {
        let client = try await makeReadyClient { name, _ in
            MCPCallResult(content: [.text("called \(name)")])
        }
        let info = MCPToolInfo(name: "echo", description: "Echo", inputSchema: .object(properties: [:], required: []))
        let tool = MCPTool<EmptyContext>(info: info, client: client)
        let result = try await tool.execute(arguments: Data("{}".utf8), context: EmptyContext())
        #expect(result.content == "called echo")
        await client.shutdown()
    }

    @Test
    func executeReturnsToolResult() async throws {
        let client = try await makeReadyClient { _, _ in
            MCPCallResult(content: [.text("success")])
        }
        let info = MCPToolInfo(name: "test", description: "Test", inputSchema: .object(properties: [:], required: []))
        let tool = MCPTool<EmptyContext>(info: info, client: client)
        let result = try await tool.execute(arguments: Data("{}".utf8), context: EmptyContext())
        #expect(result.content == "success")
        #expect(result.isError == false)
        await client.shutdown()
    }

    @Test
    func executeWithIsError() async throws {
        let client = try await makeReadyClient { _, _ in
            MCPCallResult(content: [.text("error occurred")], isError: true)
        }
        let info = MCPToolInfo(name: "test", description: "Test", inputSchema: .object(properties: [:], required: []))
        let tool = MCPTool<EmptyContext>(info: info, client: client)
        let result = try await tool.execute(arguments: Data("{}".utf8), context: EmptyContext())
        #expect(result.isError == true)
        await client.shutdown()
    }

    @Test
    func mcpErrorWrappedAsAgentError() async throws {
        let transport = DynamicMCPTransport { data in
            guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else { return nil }
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            switch request.method {
            case "initialize":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
            case "tools/list":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.emptyToolsListResult())
            case "tools/call":
                return MCPTestHelpers.encodeErrorResponse(id: idValue, code: -32600, message: "Bad request")
            default:
                return nil
            }
        }
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()
        let info = MCPToolInfo(name: "fail", description: "Fails", inputSchema: .object(properties: [:], required: []))
        let tool = MCPTool<EmptyContext>(info: info, client: client)
        do {
            _ = try await tool.execute(arguments: Data("{}".utf8), context: EmptyContext())
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .toolExecutionFailed(toolName, _) = error else {
                Issue.record("Expected toolExecutionFailed, got \(error)")
                return
            }
            #expect(toolName == "fail")
        }
        await client.shutdown()
    }

    @Test
    func cancellationPropagates() async throws {
        let transport = DynamicMCPTransport { data in
            guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else { return nil }
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            switch request.method {
            case "initialize":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
            case "tools/list":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.emptyToolsListResult())
            case "tools/call":
                return nil
            default:
                return nil
            }
        }
        let client = MCPClient(
            serverName: "test",
            transport: transport,
            toolCallTimeout: .milliseconds(200)
        )
        try await client.connectAndInitialize()
        let info = MCPToolInfo(name: "slow", description: "Slow", inputSchema: .object(properties: [:], required: []))
        let tool = MCPTool<EmptyContext>(info: info, client: client)

        let task = Task {
            try await tool.execute(arguments: Data("{}".utf8), context: EmptyContext())
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected error")
        } catch is CancellationError {
            // expected
        } catch is AgentError {
            // expected: MCPTool wraps errors as toolExecutionFailed
        }
        await client.shutdown()
    }

    @Test
    func singleTextContent() {
        let result = MCPCallResult(content: [.text("hello")])
        let toolResult = result.toToolResult()
        #expect(toolResult.content == "hello")
        #expect(toolResult.isError == false)
    }

    @Test
    func missingContentThrows() {
        let data = Data(#"{"isError":false}"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MCPCallResult.self, from: data)
        }
    }

    @Test
    func nullContentThrows() {
        let data = Data(#"{"content":null,"isError":false}"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MCPCallResult.self, from: data)
        }
    }

    @Test
    func malformedTextContentThrows() {
        let data = Data(#"{"content":[{"type":"text"}]}"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MCPCallResult.self, from: data)
        }
    }

    @Test
    func malformedBinaryContentThrows() {
        let missingData = Data(#"{"content":[{"type":"image","mimeType":"image/png"}]}"#.utf8)
        let invalidBase64 = Data(#"{"content":[{"type":"audio","data":"%%%","mimeType":"audio/wav"}]}"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MCPCallResult.self, from: missingData)
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MCPCallResult.self, from: invalidBase64)
        }
    }

    @Test
    func malformedResourceContentThrows() {
        let data = Data(#"{"content":[{"type":"resource"}]}"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MCPCallResult.self, from: data)
        }
    }

    @Test
    func malformedContentArrayElementThrows() {
        let data = Data(#"{"content":[{"type":"text","text":"ok"},{"type":"text"}]}"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MCPCallResult.self, from: data)
        }
    }

    @Test
    func invalidIsErrorThrows() {
        let data = Data(#"{"isError":"false","content":[{"type":"text","text":"ok"}]}"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MCPCallResult.self, from: data)
        }
    }

    @Test
    func multipleTextContentJoined() {
        let result = MCPCallResult(content: [.text("line 1"), .text("line 2")])
        let toolResult = result.toToolResult()
        #expect(toolResult.content == "line 1\nline 2")
    }

    @Test
    func structuredContentPrecedence() {
        let structured = Data(#"{"key":"value"}"#.utf8)
        let result = MCPCallResult(
            content: [.text("ignored")],
            structuredContent: structured
        )
        let toolResult = result.toToolResult()
        #expect(toolResult.content == #"{"key":"value"}"#)
    }

    @Test
    func imagePlaceholder() {
        let result = MCPCallResult(content: [.image(data: Data([0x89, 0x50]), mimeType: "image/png")])
        let toolResult = result.toToolResult()
        #expect(toolResult.content == "[Image: image/png]")
    }

    @Test
    func audioPlaceholder() {
        let result = MCPCallResult(content: [.audio(data: Data([0x00]), mimeType: "audio/wav")])
        let toolResult = result.toToolResult()
        #expect(toolResult.content == "[Audio: audio/wav]")
    }

    @Test
    func resourceLinkWithName() {
        let result = MCPCallResult(content: [.resourceLink(uri: "file:///test.txt", name: "Test File")])
        let toolResult = result.toToolResult()
        #expect(toolResult.content == "[Test File](file:///test.txt)")
    }

    @Test
    func resourceLinkWithoutName() {
        let result = MCPCallResult(content: [.resourceLink(uri: "file:///test.txt", name: nil)])
        let toolResult = result.toToolResult()
        #expect(toolResult.content == "file:///test.txt")
    }

    @Test
    func embeddedResourceWithText() {
        let result = MCPCallResult(content: [
            .embeddedResource(uri: "file:///doc.md", mimeType: "text/markdown", text: "# Hello")
        ])
        let toolResult = result.toToolResult()
        #expect(toolResult.content == "# Hello")
    }

    @Test
    func emptyContentArray() {
        let result = MCPCallResult(content: [])
        let toolResult = result.toToolResult()
        #expect(toolResult.content == "")
    }

    @Test
    func isErrorFlagPropagates() {
        let result = MCPCallResult(content: [.text("error")], isError: true)
        let toolResult = result.toToolResult()
        #expect(toolResult.isError == true)
    }
}

private func callResultToJSONValue(_ result: MCPCallResult) -> JSONValue {
    let contentValues: [JSONValue] = result.content.map { item in
        switch item {
        case let .text(text):
            .object(["type": .string("text"), "text": .string(text)])
        case let .image(data, mimeType):
            .object([
                "type": .string("image"),
                "data": .string(data.base64EncodedString()),
                "mimeType": .string(mimeType)
            ])
        case let .audio(data, mimeType):
            .object([
                "type": .string("audio"),
                "data": .string(data.base64EncodedString()),
                "mimeType": .string(mimeType)
            ])
        case let .resourceLink(uri, name):
            .object(["type": .string("resource"), "resource": .object(
                ["uri": .string(uri)].merging(name.map { ["name": .string($0)] } ?? [:]) { _, new in new }
            )])
        case let .embeddedResource(uri, mimeType, text):
            .object(["type": .string("resource"), "resource": .object(
                ["uri": .string(uri)]
                    .merging(mimeType.map { ["mimeType": .string($0)] } ?? [:]) { _, new in new }
                    .merging(text.map { ["text": .string($0)] } ?? [:]) { _, new in new }
            )])
        }
    }
    var dict: [String: JSONValue] = [
        "content": .array(contentValues),
        "isError": .bool(result.isError),
    ]
    if let structuredContent = result.structuredContent,
       let value = try? JSONDecoder().decode(JSONValue.self, from: structuredContent) {
        dict["structuredContent"] = value
    }
    return .object(dict)
}
