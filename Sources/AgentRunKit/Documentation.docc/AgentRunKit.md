# ``AgentRunKit``

A Swift 6 framework for building LLM-powered agents with type-safe tool calling, streaming, sub-agent composition, and multi-provider support.

## Overview

AgentRunKit provides a complete agent loop (generate a response, execute tool calls, repeat until done) with zero external dependencies. It works with any LLM provider through a unified ``LLMClient`` protocol.

- **Agent loop**: ``Agent`` runs the full generate, tool-call, repeat cycle with configurable iteration limits and token budgets
- **Streaming**: SSE parsing, `AsyncThrowingStream<StreamEvent, Error>`, and ``AgentStream`` for SwiftUI with `@Observable`
- **Type-safe tools**: ``Tool`` with compile-time schema validation via ``SchemaDecoder`` and ``SchemaProviding``
- **Sub-agent composition**: ``SubAgentTool`` wraps agents as callable tools with depth limiting and streaming propagation
- **Context management**: Observation pruning, LLM-based summarization, configurable compaction thresholds
- **Structured output**: ``ResponseFormat`` with `jsonSchema(T.self)` for any `Codable & SchemaProviding` type
- **Multi-provider**: OpenAI, Anthropic, Gemini, Vertex AI, Responses API, plus on-device via Foundation Models and MLX
- **Multimodal**: Images, audio, video, PDF as ``ContentPart`` variants, plus TTS synthesis
- **MCP client**: ``MCPClient`` with stdio transport, JSON-RPC, tool discovery and execution

```swift
import AgentRunKit

let client = OpenAIClient.openAI(apiKey: "sk-...", model: "gpt-5.4")

let weatherTool = try Tool<WeatherParams, String, EmptyContext>(
    name: "get_weather",
    description: "Get the current weather"
) { params, _ in
    "72°F and sunny in \(params.city)"
}

let agent = Agent(client: client, tools: [weatherTool])
let result = try await agent.run(
    userMessage: "What's the weather in SF?",
    context: EmptyContext()
)
if let content = result.content {
    print(content)
}
```

If a run ends because `maxIterations` or `tokenBudget` is reached before the model calls `finish`, ``Agent/run(userMessage:history:context:tokenBudget:requestContext:approvalHandler:)`` still returns an ``AgentResult`` with a structural ``FinishReason`` and `content == nil`.

For a complete walkthrough, see <doc:GettingStarted>.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:AgentAndChat>
- <doc:DefiningTools>

### Streaming and UI

- <doc:StreamingAndSwiftUI>
- ``StreamEvent``
- ``AgentStream``
- ``ToolCallInfo``

### Tool Approval

- <doc:ToolApproval>
- ``ToolApprovalPolicy``
- ``ToolApprovalRequest``
- ``ToolApprovalDecision``

### Agent Composition

- <doc:SubAgents>
- <doc:ContextManagement>
- ``SubAgentTool``
- ``SubAgentContext``

### Connecting to Providers

- <doc:LLMProviders>
- ``LLMClient``
- ``OpenAIClient``
- ``OpenAIChatProfile``
- ``OpenAIChatAssistantReplayProfile``
- ``AnthropicClient``
- ``AnthropicReasoningOptions``
- ``GeminiClient``
- ``VertexAnthropicClient``
- ``VertexGoogleClient``
- ``ResponsesAPIClient``
- ``RetryPolicy``
- ``GoogleAuthService``

### Provider Capabilities

- ``OpenAIChatCapabilities``
- ``AnthropicCapabilities``
- ``AnthropicModelFamily``
- ``GeminiCapabilities``
- ``GeminiModelFamily``
- ``OpaqueResponseItem``

### Structured Output

- <doc:StructuredOutput>
- ``ResponseFormat``
- ``SchemaProviding``
- ``JSONSchema``
- ``SchemaDecoder``
- ``SchemaDecoderError``

### Building Agents

- ``Agent``
- ``Chat``
- ``AgentConfiguration``
- ``AgentResult``
- ``FinishReason``
- ``FinishArguments``
- ``ContextBudget``
- ``ContextBudgetConfig``
- ``ContextBudgetVisibilityFormat``

### Defining Tools

- ``AnyTool``
- ``Tool``
- ``ToolContext``
- ``ToolResult``
- ``EmptyContext``
- ``ToolDefinition``

### Messages

- ``ChatMessage``
- ``AssistantMessage``
- ``ContentPart``
- ``ToolCall``
- ``ToolCallKind``
- ``TokenUsage``
- ``ReasoningContent``
- ``ReasoningConfig``

### Multimodal and Audio

- <doc:MultimodalAndAudio>
- ``AudioInputFormat``
- ``TTSClient``
- ``TTSProvider``
- ``TTSProviderConfig``
- ``TTSAudioFormat``
- ``OpenAITTSProvider``
- ``TTSSegment``
- ``TTSOptions``

### MCP Integration

- <doc:MCPIntegration>
- ``MCPClient``
- ``MCPSession``
- ``MCPTool``
- ``MCPToolInfo``
- ``MCPServerConfiguration``
- ``StdioMCPTransport``
- ``MCPTransport``
- ``MCPContent``
- ``MCPCallResult``

### MCP Wire Format

- ``JSONRPCID``
- ``JSONRPCRequest``
- ``JSONRPCNotification``
- ``JSONRPCErrorObject``
- ``JSONRPCResponse``
- ``JSONRPCMessage``

### Errors

- ``AgentError``
- ``MalformedStreamReason``
- ``MCPError``
- ``TTSError``
- ``TransportError``

### Supporting Types

- ``RequestContext``
- ``JSONValue``
- ``StreamDelta``
- ``ThinkTagParser``
- ``TranscriptionOptions``
- ``TranscriptionAudioFormat``
