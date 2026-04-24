# MCP Integration

Connect to external tool servers using the Model Context Protocol.

## Overview

[MCP](https://modelcontextprotocol.io) is a standard protocol for exposing tools from external processes. AgentRunKit includes a full MCP client: configure servers, discover their tools at startup, and pass those tools to ``Agent`` or ``Chat`` alongside native tools.

## Configuring Servers

``MCPServerConfiguration`` describes how to launch and communicate with an MCP server.

```swift
let config = MCPServerConfiguration(
    name: "filesystem",
    command: "/usr/local/bin/mcp-filesystem",
    arguments: ["--root", "/tmp"],
    environment: ["LOG_LEVEL": "warn"],
    initializationTimeout: .seconds(10),
    toolCallTimeout: .seconds(30)
)
```

| Property | Default | Description |
|---|---|---|
| `name` | (required) | Unique identifier for this server |
| `command` | (required) | Absolute path to the server executable |
| `arguments` | `[]` | Command-line arguments |
| `environment` | `nil` | Extra environment variables (merged with the current process environment) |
| `workingDirectory` | `nil` | Working directory for the server process |
| `initializationTimeout` | 30s | Deadline for the handshake and tool discovery |
| `toolCallTimeout` | 60s | Per-call deadline for `tools/call` requests |

## Session Lifecycle

``MCPSession`` manages the full lifecycle: process launch, protocol handshake, tool discovery, and shutdown. Construct it with one or more configurations, then use the ``MCPSession/withTools(_:)`` closure to scope the connection.

```swift
let session = MCPSession(configurations: [filesystemConfig, searchConfig])

let result: AgentResult = try await session.withTools { (mcpTools: [any AnyTool<EmptyContext>]) in
    let agent = Agent(client: client, tools: nativeTools + mcpTools)
    return try await agent.run(userMessage: "List files in /tmp", context: EmptyContext())
}
```

When the closure returns (or throws), all servers are shut down and their processes terminated. Servers connect in parallel, so adding more servers does not increase startup time linearly.

## Multiple Servers

Pass multiple ``MCPServerConfiguration`` values to a single session. All servers connect concurrently. Tool names must be globally unique across all connected servers. If two servers expose a tool with the same name, ``MCPSession/withTools(_:)`` throws ``MCPError/duplicateToolName(tool:servers:)``.

## MCPTool

``MCPTool`` adapts each discovered MCP tool to the ``AnyTool`` protocol. Once inside the `withTools` closure, MCP tools are indistinguishable from native ``Tool`` instances. The agent calls them through the same interface, and their results follow the same ``ToolResult`` type.

## Checkpoint Binding Validation

When a checkpointed run includes MCP tool calls, the agent loop records each participating tool as an ``MCPToolBinding`` in ``AgentCheckpoint/mcpToolBindings``. On resume, ``Agent/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` validates that every recorded binding has a live counterpart with the same `serverName` and `toolName`. Missing bindings throw ``AgentCheckpointError/mcpBindingMismatch(_:)`` before any event is yielded, catching deployment skew where the resuming agent is configured against a different MCP server set. See <doc:CheckpointAndResume>.

## Error Handling

``MCPError`` covers all failure modes:

| Case | Meaning |
|---|---|
| ``MCPError/connectionFailed(_:)`` | Transport failed to connect or server process did not start |
| ``MCPError/serverStartFailed(server:message:)`` | Named server failed during launch |
| ``MCPError/protocolVersionMismatch(requested:supported:)`` | Client and server disagree on protocol version |
| ``MCPError/requestTimeout(method:)`` | A JSON-RPC request exceeded its deadline |
| ``MCPError/duplicateToolName(tool:servers:)`` | Two servers expose the same tool name |
| ``MCPError/jsonRPCError(code:message:)`` | Server returned a JSON-RPC error response |
| ``MCPError/transportClosed`` | The transport connection dropped unexpectedly |
| ``MCPError/invalidResponse(_:)`` | Response could not be interpreted |
| ``MCPError/decodingFailed(_:)`` | Response payload failed to decode |

## JSON-RPC Lifecycle

``MCPClient`` implements the [MCP specification](https://modelcontextprotocol.io) lifecycle over JSON-RPC:

1. **initialize**: client sends protocol version and capabilities, server responds with its version
2. **notifications/initialized**: client confirms the handshake
3. **tools/list**: client discovers available tools (paginated via cursor)
4. **tools/call**: client invokes a tool by name with JSON arguments
5. **shutdown**: client closes the transport and terminates the server process

``MCPSession`` handles steps 1 through 3 automatically before entering the `withTools` closure, and step 5 when the closure exits.

## Custom Transports

The built-in ``StdioMCPTransport`` communicates over stdin/stdout (macOS only). To use a different transport (WebSocket, HTTP, etc.), conform to ``MCPTransport``:

```swift
public protocol MCPTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func messages() -> AsyncThrowingStream<Data, Error>
}
```

Pass a custom transport to ``MCPClient`` directly:

```swift
let client = MCPClient(
    serverName: "remote",
    transport: MyWebSocketTransport(url: endpoint),
    initializationTimeout: .seconds(15),
    toolCallTimeout: .seconds(60)
)
```

For session-based usage with custom transports, use the internal initializer that accepts a transport factory.

## See Also

- <doc:DefiningTools>
- <doc:AgentAndChat>
- <doc:CheckpointAndResume>
- ``MCPClient``
- ``MCPSession``
- ``MCPTool``
- ``MCPToolInfo``
- ``MCPToolBinding``
- ``MCPServerConfiguration``
- ``StdioMCPTransport``
- ``MCPTransport``
- ``MCPError``
