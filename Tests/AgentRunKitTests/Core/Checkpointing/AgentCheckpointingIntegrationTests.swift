@testable import AgentRunKit
import Foundation
import Testing

private let echoToolCallDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_echo", name: "echo", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"message": "hi"}"#),
    .finished(usage: TokenUsage(input: 10, output: 5)),
]

private let finishDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
    .finished(usage: TokenUsage(input: 5, output: 5)),
]

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private func makeEchoTool() throws -> Tool<EchoParams, EchoOutput, EmptyContext> {
    try Tool<EchoParams, EchoOutput, EmptyContext>(
        name: "echo",
        description: "Echoes input",
        executor: { params, _ in EchoOutput(echoed: params.message) }
    )
}

private func makeRemoteToolTransport(schema: JSONValue) -> DynamicMCPTransport {
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
                    tools: [
                        .init(name: "remote_tool", description: "Remote", schema: schema),
                        .init(name: "unused_tool", description: "Unused", schema: schema),
                    ]
                )
            )
        case "tools/call":
            return MCPTestHelpers.encodeResponse(
                id: idValue,
                result: MCPTestHelpers.callToolResult(text: "remote result")
            )
        default:
            return nil
        }
    }
}

private func runStream(
    sequences: [[StreamDelta]],
    tools: [any AnyTool<EmptyContext>],
    checkpointer: (any AgentCheckpointer)?,
    sessionID: SessionID? = nil,
    contextWindowSize: Int? = nil,
    configuration: AgentConfiguration = AgentConfiguration()
) async throws -> [StreamEvent] {
    let client = StreamingMockLLMClient(streamSequences: sequences, contextWindowSize: contextWindowSize)
    let agent = Agent<EmptyContext>(client: client, tools: tools, configuration: configuration)
    var events: [StreamEvent] = []
    for try await event in agent.stream(
        userMessage: "Hi", context: EmptyContext(),
        sessionID: sessionID, checkpointer: checkpointer
    ) {
        events.append(event)
    }
    return events
}

struct AgentCheckpointingIntegrationTests {
    @Test
    func streamSavesCheckpointAfterToolResults() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        _ = try await runStream(
            sequences: [echoToolCallDeltas, finishDeltas],
            tools: [makeEchoTool()],
            checkpointer: backend,
            sessionID: session
        )
        let ids = try await backend.list(session: session)
        #expect(ids.count == 1)
        let firstCheckpoint = try await backend.load(#require(ids.first))
        let hasToolMessage = firstCheckpoint.messages.contains { message in
            if case .tool = message { return true }
            return false
        }
        #expect(hasToolMessage)
        #expect(firstCheckpoint.iteration == 1)
    }

    @Test
    func streamSavesMCPToolBindingsAfterToolResults() async throws {
        let backend = InMemoryCheckpointer()
        let sessionID = SessionID()
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let mcpSession = MCPSession(configurations: [config]) { _ in
            makeRemoteToolTransport(schema: schema)
        }
        let remoteToolCallDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_remote", name: "remote_tool", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]

        try await mcpSession.withTools { (mcpTools: [any AnyTool<EmptyContext>]) in
            _ = try await runStream(
                sequences: [remoteToolCallDeltas, finishDeltas],
                tools: mcpTools,
                checkpointer: backend,
                sessionID: sessionID
            )
            let ids = try await backend.list(session: sessionID)
            let checkpoint = try await backend.load(#require(ids.first))
            #expect(checkpoint.mcpToolBindings == [
                MCPToolBinding(serverName: "server1", toolName: "remote_tool")
            ])
        }
    }

    @Test
    func mcpToolBindingsRecognizeAssistantAndToolMessagesIndependently() async throws {
        let schema = MCPTestHelpers.toolSchema(properties: [:])
        let config = MCPServerConfiguration(name: "server1", command: "/bin/test")
        let mcpSession = MCPSession(configurations: [config]) { _ in
            makeRemoteToolTransport(schema: schema)
        }

        try await mcpSession.withTools { (mcpTools: [any AnyTool<EmptyContext>]) in
            let agent = Agent<EmptyContext>(
                client: StreamingMockLLMClient(),
                tools: mcpTools
            )
            let expected: Set<MCPToolBinding> = [
                MCPToolBinding(serverName: "server1", toolName: "remote_tool")
            ]

            #expect(agent.mcpToolBindings(in: [
                .assistant(AssistantMessage(
                    content: "",
                    toolCalls: [ToolCall(id: "call_remote", name: "remote_tool", arguments: "{}")]
                )),
            ]) == expected)

            #expect(agent.mcpToolBindings(in: [
                .tool(id: "call_remote", name: "remote_tool", content: "{}")
            ]) == expected)

            #expect(agent.mcpToolBindings(in: [
                .assistant(AssistantMessage(
                    content: "",
                    toolCalls: [ToolCall(id: "call_unused", name: "unused_tool", arguments: "{}")]
                )),
            ]) == [
                MCPToolBinding(serverName: "server1", toolName: "unused_tool")
            ])
        }
    }

    @Test
    func streamSavesCheckpointMetadataAfterEachNonTerminalIteration() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let echoIteration1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"first"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let echoIteration2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"second"}"#),
            .finished(usage: TokenUsage(input: 17, output: 11)),
        ]
        _ = try await runStream(
            sequences: [echoIteration1, echoIteration2, finishDeltas],
            tools: [makeEchoTool()],
            checkpointer: backend,
            sessionID: session
        )
        let ids = try await backend.list(session: session)
        #expect(ids.count == 2)
        let firstCheckpoint = try await backend.load(ids[0])
        let secondCheckpoint = try await backend.load(ids[1])

        #expect(firstCheckpoint.iteration == 1)
        #expect(firstCheckpoint.iterationUsage == TokenUsage(input: 10, output: 5))
        #expect(firstCheckpoint.tokenUsage == TokenUsage(input: 10, output: 5))
        #expect(firstCheckpoint.sessionID == session)

        #expect(secondCheckpoint.iteration == 2)
        #expect(secondCheckpoint.iterationUsage == TokenUsage(input: 17, output: 11))
        #expect(secondCheckpoint.tokenUsage == TokenUsage(input: 27, output: 16))
    }

    @Test
    func streamSavesSessionAllowlistAfterApproveAlways() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let echoTool = try makeEchoTool()
        let approveEchoCall: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"first"}"#),
            .finished(usage: TokenUsage(input: 5, output: 3)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [approveEchoCall, finishDeltas])
        let agent = Agent<EmptyContext>(
            client: client, tools: [echoTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        var events: [StreamEvent] = []
        for try await event in agent.stream(
            userMessage: "Hi", context: EmptyContext(),
            approvalHandler: { _ in .approveAlways },
            sessionID: session, checkpointer: backend
        ) {
            events.append(event)
        }
        let ids = try await backend.list(session: session)
        let checkpoint = try await backend.load(#require(ids.first))
        #expect(checkpoint.sessionAllowlist.contains("echo"))
    }
}
