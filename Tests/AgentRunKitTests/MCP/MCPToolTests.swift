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
        } catch is CancellationError {} catch is AgentError {}
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

    @Test(arguments: [
        #"{"zeta":[{"zeta":true,"alpha":"雪"},{"zeta":false,"alpha":"first"}],"alpha":"{ \"z\": 1, \"a\": 2 }"}"#,
        #"{"alpha":"{ \"z\": 1, \"a\": 2 }","zeta":[{"alpha":"雪","zeta":true},{"alpha":"first","zeta":false}]}"#
    ])
    func decodedStructuredContentUsesDeterministicObjectOrder(structuredJSON: String) throws {
        let wire = #"{"content":[{"type":"text","text":"ignored"}],"isError":true,"#
            + #""structuredContent":\#(structuredJSON)}"#
        let result = try JSONDecoder().decode(MCPCallResult.self, from: Data(wire.utf8))
        let expected = #"{"alpha":"{ \"z\": 1, \"a\": 2 }","zeta":[{"alpha":"雪","zeta":true},"#
            + #"{"alpha":"first","zeta":false}]}"#

        #expect(result.structuredContent == Data(expected.utf8))
        #expect(result.toToolResult() == ToolResult(content: expected, isError: true))
    }

    @Test
    func structuredContentPrecedence() {
        let structured = Data(#"{ "zeta": 1, "alpha": 2 }"#.utf8)
        let result = MCPCallResult(
            content: [.text("ignored")],
            structuredContent: structured
        )
        let toolResult = result.toToolResult()
        #expect(toolResult.content == #"{ "zeta": 1, "alpha": 2 }"#)
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
    func decodedResourceLinkPreservesMixedText() throws {
        let json = #"{"content":[{"type":"text","text":"Read this"},"#
            + #"{"type":"resource_link","uri":"file:///test.txt","name":"Test File"}]}"#
        let result = try JSONDecoder().decode(MCPCallResult.self, from: Data(json.utf8))
        #expect(result.content == [.text("Read this"), .resourceLink(uri: "file:///test.txt", name: "Test File")])
        #expect(result.toToolResult().content == "Read this\n[Test File](file:///test.txt)")
    }

    @Test
    func embeddedResourceWithText() {
        let result = MCPCallResult(content: [
            .embeddedResource(uri: "file:///doc.md", mimeType: "text/markdown", content: .text("# Hello"))
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

@Suite(.tags(.wireFormat))
struct MCPResourceDecodingTests {
    @Test(arguments: [
        (#"{"uri":"file:///resource","text":"hello"}"#,
         MCPContent.embeddedResource(uri: "file:///resource", mimeType: nil, content: .text("hello"))),
        (#"{"uri":"file:///resource","text":"hello","mimeType":"text/plain"}"#,
         .embeddedResource(uri: "file:///resource", mimeType: "text/plain", content: .text("hello"))),
        (#"{"uri":"file:///resource","blob":"AAH+/w=="}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .blob(Data([0, 1, 254, 255])))),
        (#"{"uri":"file:///resource","blob":"AAH+/w==","mimeType":"application/octet-stream"}"#,
         .embeddedResource(uri: "file:///resource", mimeType: "application/octet-stream",
                           content: .blob(Data([0, 1, 254, 255])))),
        (#"{"uri":"file:///resource","blob":""}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .blob(Data()))),
        (#"{"uri":"file:///resource","text":"hello","blob":"AAH+/w=="}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .text("hello"))),
        (#"{"uri":"file:///resource","text":"","blob":"AAH+/w=="}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .text(""))),
        (#"{"uri":"file:///resource","text":"hello","blob":"%%%"}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .text("hello"))),
        (#"{"uri":"file:///resource","text":"hello","blob":42}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .text("hello"))),
        (#"{"uri":"file:///resource","text":null,"blob":"AAH+/w=="}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .blob(Data([0, 1, 254, 255])))),
        (#"{"uri":"file:///resource","text":42,"blob":"AAH+/w=="}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .blob(Data([0, 1, 254, 255])))),
        (#"{"uri":"file:///resource","text":1e400,"blob":"AA=="}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .blob(Data([0])))),
        (#"{"uri":"file:///resource","text":[1e400],"blob":"AA=="}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .blob(Data([0])))),
        (#"{"uri":"file:///resource","text":{},"blob":"AAH+/w=="}"#,
         .embeddedResource(uri: "file:///resource", mimeType: nil, content: .blob(Data([0, 1, 254, 255]))))
    ])
    func embeddedResourceSelectsAValidRepresentation(resource: String, expected: MCPContent) throws {
        let json = #"{"content":[{"type":"resource","resource":\#(resource)}]}"#
        let result = try JSONDecoder().decode(MCPCallResult.self, from: Data(json.utf8))
        #expect(result.content == [expected])
    }

    @Test
    func decodedBinaryResourceRemainsAvailableBehindTextProjection() throws {
        let json = #"{"content":[{"type":"resource","resource":{"uri":"file:///binary","blob":"AAH+/w=="}}]}"#
        let result = try JSONDecoder().decode(MCPCallResult.self, from: Data(json.utf8))
        #expect(result.toToolResult().content == "[Embedded resource]")
        #expect(result.content == [
            .embeddedResource(uri: "file:///binary", mimeType: nil, content: .blob(Data([0, 1, 254, 255])))
        ])
    }

    @Test(arguments: [
        (#"{"type":"resource_link","name":"name"}"#, ["uri"]),
        (#"{"type":"resource_link","uri":"file:///resource"}"#, ["name"]),
        (#"{"type":"resource_link","uri":null,"name":"name"}"#, ["uri"]),
        (#"{"type":"resource_link","uri":42,"name":"name"}"#, ["uri"]),
        (#"{"type":"resource_link","uri":"file:///resource","name":null}"#, ["name"]),
        (#"{"type":"resource_link","uri":"file:///resource","name":42}"#, ["name"]),
        (#"{"type":"resource_link","resource":{"uri":"file:///resource","name":"name"}}"#, ["uri"]),
        (#"{"type":"resource"}"#, ["resource"]),
        (#"{"type":"resource","resource":null}"#, ["resource"]),
        (#"{"type":"resource","resource":42}"#, ["resource"]),
        (#"{"type":"resource","resource":{"text":"hello"}}"#, ["resource", "uri"]),
        (#"{"type":"resource","resource":{"uri":null,"text":"hello"}}"#, ["resource", "uri"]),
        (#"{"type":"resource","resource":{"uri":42,"blob":"AA=="}}"#, ["resource", "uri"]),
        (#"{"type":"resource","resource":{"uri":"file:///r","mimeType":null,"text":"hello"}}"#,
         ["resource", "mimeType"]),
        (#"{"type":"resource","resource":{"uri":"file:///r","mimeType":42,"blob":"AA=="}}"#,
         ["resource", "mimeType"]),
        (#"{"type":"resource","resource":{"uri":"file:///resource"}}"#, ["resource"]),
        (#"{"type":"resource","resource":{"uri":"file:///resource","name":"old link"}}"#, ["resource"]),
        (#"{"type":"resource","resource":{"uri":"file:///resource","text":null}}"#, ["resource"]),
        (#"{"type":"resource","resource":{"uri":"file:///resource","text":42}}"#, ["resource"]),
        (#"{"type":"resource","resource":{"uri":"file:///resource","blob":null}}"#, ["resource", "blob"]),
        (#"{"type":"resource","resource":{"uri":"file:///resource","blob":42}}"#, ["resource", "blob"]),
        (#"{"type":"resource","resource":{"uri":"file:///resource","blob":"%%%"}}"#, ["resource", "blob"]),
        (#"{"type":"resource","resource":{"uri":"file:///resource","blob":"a"}}"#, ["resource", "blob"])
    ])
    func malformedResourceReportsItsWirePath(content: String, expectedPath: [String]) throws {
        let json = #"{"content":[\#(content)]}"#
        do {
            _ = try JSONDecoder().decode(MCPCallResult.self, from: Data(json.utf8))
            Issue.record("Expected malformed resource content to fail")
        } catch let error as DecodingError {
            let path: [any CodingKey]
            switch error {
            case let .keyNotFound(key, context): path = context.codingPath + [key]
            case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
                path = context.codingPath
            @unknown default:
                Issue.record("Unexpected decoding error")
                return
            }
            #expect(path.map { $0.intValue.map(String.init) ?? $0.stringValue } == ["content", "0"] + expectedPath)
        }
    }
}

private func callResultToJSONValue(_ result: MCPCallResult) -> JSONValue {
    let contentValues: [JSONValue] = result.content.map { item in
        switch item {
        case let .text(text):
            return .object(["type": .string("text"), "text": .string(text)])
        case let .image(data, mimeType):
            return .object([
                "type": .string("image"),
                "data": .string(data.base64EncodedString()),
                "mimeType": .string(mimeType)
            ])
        case let .audio(data, mimeType):
            return .object([
                "type": .string("audio"),
                "data": .string(data.base64EncodedString()),
                "mimeType": .string(mimeType)
            ])
        case let .resourceLink(uri, name):
            return .object(["type": .string("resource_link"), "uri": .string(uri), "name": .string(name)])
        case let .embeddedResource(uri, mimeType, content):
            var resource: [String: JSONValue] = ["uri": .string(uri)]
            if let mimeType { resource["mimeType"] = .string(mimeType) }
            switch content {
            case let .text(text): resource["text"] = .string(text)
            case let .blob(data): resource["blob"] = .string(data.base64EncodedString())
            }
            return .object(["type": .string("resource"), "resource": .object(resource)])
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
