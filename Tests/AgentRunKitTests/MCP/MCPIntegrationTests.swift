@testable import AgentRunKit
import Foundation
import Testing

private func makeStandardTransport(
    tools: [MCPTestHelpers.MockTool] = [],
    toolCallHandler: (@Sendable (String) async throws -> String)? = nil
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
            if let handler = toolCallHandler {
                let text = try await handler(name)
                return MCPTestHelpers.encodeResponse(
                    id: idValue,
                    result: MCPTestHelpers.callToolResult(text: text)
                )
            }
            return MCPTestHelpers.encodeResponse(
                id: idValue,
                result: MCPTestHelpers.callToolResult(text: "result from \(name)")
            )
        default:
            return nil
        }
    }
}

struct MCPIntegrationTests {
    @Test
    func fullLifecycle() async throws {
        let schema = MCPTestHelpers.toolSchema(
            properties: ["query": .object(["type": .string("string")])],
            required: ["query"]
        )
        let transport = makeStandardTransport(
            tools: [.init(name: "search", description: "Search tool", schema: schema)]
        )
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()

        let tools = await client.listTools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "search")

        let result = try await client.callTool(
            name: "search",
            arguments: Data(#"{"query":"test"}"#.utf8)
        )
        guard case let .text(text) = result.content.first else {
            Issue.record("Expected text content")
            return
        }
        #expect(text == "result from search")
        await client.shutdown()
    }

    @Test
    func agentWithMCPTool() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let session = MCPSession(configurations: [config]) { _ in
            makeStandardTransport(tools: [.init(name: "remote_tool", description: "Remote", schema: schema)]) { _ in
                "remote result"
            }
        }

        try await session.withTools { (mcpTools: [any AnyTool<EmptyContext>]) in
            let toolCall = ToolCall(id: "call_1", name: "remote_tool", arguments: "{}")
            let finishCall = ToolCall(
                id: "call_2",
                name: "finish",
                arguments: #"{"content": "Done with remote"}"#
            )
            let llm = IntegrationMockLLMClient(responses: [
                AssistantMessage(content: "", toolCalls: [toolCall]),
                AssistantMessage(content: "", toolCalls: [finishCall]),
            ])
            let agent = Agent<EmptyContext>(client: llm, tools: mcpTools)
            let result = try await agent.run(userMessage: "Use the tool", context: EmptyContext())
            #expect(result.content == "Done with remote")
        }
    }

    @Test
    func agentWithMCPToolError() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let session = MCPSession(configurations: [config]) { _ in
            DynamicMCPTransport { data in
                guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else { return nil }
                let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
                switch request.method {
                case "initialize":
                    return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
                case "tools/list":
                    return MCPTestHelpers.encodeResponse(
                        id: idValue,
                        result: MCPTestHelpers.toolsListResult(
                            tools: [.init(name: "error_tool", description: "Error", schema: schema)]
                        )
                    )
                case "tools/call":
                    return MCPTestHelpers.encodeResponse(
                        id: idValue,
                        result: MCPTestHelpers.callToolResult(text: "something went wrong", isError: true)
                    )
                default:
                    return nil
                }
            }
        }

        try await session.withTools { (mcpTools: [any AnyTool<EmptyContext>]) in
            let toolCall = ToolCall(id: "call_1", name: "error_tool", arguments: "{}")
            let finishCall = ToolCall(
                id: "call_2",
                name: "finish",
                arguments: #"{"content": "Handled error"}"#
            )
            let llm = IntegrationCapturingMockLLMClient(responses: [
                AssistantMessage(content: "", toolCalls: [toolCall]),
                AssistantMessage(content: "", toolCalls: [finishCall]),
            ])
            let agent = Agent<EmptyContext>(client: llm, tools: mcpTools)
            let result = try await agent.run(userMessage: "Try tool", context: EmptyContext())
            #expect(result.content == "Handled error")

            let messages = await llm.capturedMessages
            let toolMessage = messages.first { msg in
                if case .tool = msg { return true }
                return false
            }
            guard case let .tool(_, _, content) = toolMessage else {
                Issue.record("Expected tool message")
                return
            }
            #expect(content.contains("something went wrong"))
        }
    }

    @Test
    func mixedLocalAndMCPTools() async throws {
        let localTool = try Tool<MixedParams, MixedOutput, EmptyContext>(
            name: "local_add",
            description: "Adds numbers",
            executor: { params, _ in MixedOutput(result: "sum: \(params.lhs + params.rhs)") }
        )

        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let session = MCPSession(configurations: [config]) { _ in
            makeStandardTransport(
                tools: [.init(name: "remote_fetch", description: "Fetches data", schema: schema)]
            ) { _ in
                "fetched data"
            }
        }

        try await session.withTools { (mcpTools: [any AnyTool<EmptyContext>]) in
            let allTools: [any AnyTool<EmptyContext>] = [localTool] + mcpTools
            let addCall = ToolCall(id: "call_1", name: "local_add", arguments: #"{"lhs":3,"rhs":4}"#)
            let fetchCall = ToolCall(id: "call_2", name: "remote_fetch", arguments: "{}")
            let finishCall = ToolCall(
                id: "call_3",
                name: "finish",
                arguments: #"{"content": "Both done"}"#
            )
            let llm = IntegrationMockLLMClient(responses: [
                AssistantMessage(content: "", toolCalls: [addCall, fetchCall]),
                AssistantMessage(content: "", toolCalls: [finishCall]),
            ])
            let agent = Agent<EmptyContext>(client: llm, tools: allTools)
            let result = try await agent.run(userMessage: "Do both", context: EmptyContext())
            #expect(result.content == "Both done")
        }
    }

    @Test
    func parallelMCPCalls() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let session = MCPSession(configurations: [config]) { _ in
            makeStandardTransport(tools: [
                .init(name: "tool_a", description: "A", schema: schema),
                .init(name: "tool_b", description: "B", schema: schema)
            ]) { name in
                "result_\(name)"
            }
        }

        try await session.withTools { (mcpTools: [any AnyTool<EmptyContext>]) in
            let call1 = ToolCall(id: "call_1", name: "tool_a", arguments: "{}")
            let call2 = ToolCall(id: "call_2", name: "tool_b", arguments: "{}")
            let finishCall = ToolCall(
                id: "call_3",
                name: "finish",
                arguments: #"{"content": "Parallel done"}"#
            )
            let llm = IntegrationMockLLMClient(responses: [
                AssistantMessage(content: "", toolCalls: [call1, call2]),
                AssistantMessage(content: "", toolCalls: [finishCall]),
            ])
            let agent = Agent<EmptyContext>(client: llm, tools: mcpTools)
            let result = try await agent.run(userMessage: "Do both", context: EmptyContext())
            #expect(result.content == "Parallel done")
        }
    }

    @Test
    func mcpToolTimeout() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let config = MCPServerConfiguration(
            name: "server1",
            command: "/bin/test",
            toolCallTimeout: .milliseconds(200)
        )
        let session = MCPSession(configurations: [config]) { _ in
            DynamicMCPTransport { data in
                guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else { return nil }
                let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
                switch request.method {
                case "initialize":
                    return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
                case "tools/list":
                    return MCPTestHelpers.encodeResponse(
                        id: idValue,
                        result: MCPTestHelpers.toolsListResult(
                            tools: [.init(name: "slow_tool", description: "Slow", schema: schema)]
                        )
                    )
                case "tools/call":
                    return nil
                default:
                    return nil
                }
            }
        }

        try await session.withTools { (mcpTools: [any AnyTool<EmptyContext>]) in
            let toolCall = ToolCall(id: "call_1", name: "slow_tool", arguments: "{}")
            let finishCall = ToolCall(
                id: "call_2",
                name: "finish",
                arguments: #"{"content": "Handled timeout"}"#
            )
            let llm = IntegrationMockLLMClient(responses: [
                AssistantMessage(content: "", toolCalls: [toolCall]),
                AssistantMessage(content: "", toolCalls: [finishCall]),
            ])
            let agent = Agent<EmptyContext>(client: llm, tools: mcpTools)
            let result = try await agent.run(userMessage: "Use slow tool", context: EmptyContext())
            #expect(result.content == "Handled timeout")
        }
    }

    @Test
    func invalidJsonFromServer() async throws {
        let transport = DynamicMCPTransport { data in
            guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else { return nil }
            let idValue: Int = if case let .int(val) = request.id { val } else { 0 }
            switch request.method {
            case "initialize":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.initializeResult())
            case "tools/list":
                return MCPTestHelpers.encodeResponse(id: idValue, result: MCPTestHelpers.emptyToolsListResult())
            case "tools/call":
                return MCPTestHelpers.encodeResponse(
                    id: idValue,
                    result: MCPTestHelpers.callToolResult(text: "valid response")
                )
            default:
                return nil
            }
        }
        let client = MCPClient(serverName: "test", transport: transport)
        try await client.connectAndInitialize()

        await transport.injectMessage(Data("not valid json{{{".utf8))

        let result = try await client.callTool(name: "test", arguments: Data("{}".utf8))
        guard case let .text(text) = result.content.first else {
            Issue.record("Expected text content")
            return
        }
        #expect(text == "valid response")
        await client.shutdown()
    }
}

private actor IntegrationMockLLMClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("IntegrationMockLLMClient")
    private let responses: [AssistantMessage]
    private var callIndex: Int = 0

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor IntegrationCapturingMockLLMClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("IntegrationCapturingMockLLMClient")
    private let responses: [AssistantMessage]
    private var callIndex: Int = 0
    private(set) var capturedMessages: [ChatMessage] = []

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        capturedMessages = messages
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct MixedParams: Codable, SchemaProviding {
    let lhs: Int
    let rhs: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: ["lhs": .integer(), "rhs": .integer()],
            required: ["lhs", "rhs"]
        )
    }
}

private struct MixedOutput: Codable {
    let result: String
}
