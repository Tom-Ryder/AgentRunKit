# AgentRunKit

<p align="center">
  <img src="assets/logo-dark.png" alt="AgentRunKit" width="280">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/Platforms-iOS%2018%20%7C%20macOS%2015-blue" alt="Platforms">
  <img src="https://img.shields.io/badge/SPM-compatible-brightgreen" alt="SPM">
  <img src="https://img.shields.io/badge/License-MIT-lightgrey" alt="License">
</p>

<p align="center">
  A lightweight Swift 6 framework for building LLM-powered agents with type-safe tool calling.
</p>

<p align="center">
  <b>Zero dependencies</b> · <b>Full Sendable</b> · <b>Async/await</b> · <b>Multi-provider</b> · <b>MCP</b> · <b>Production-ready</b>
</p>

---

## Table of Contents

- [Quick Start](#quick-start)
- [Installation](#installation)
- [Core Concepts](#core-concepts)
  - [When to Use What](#when-to-use-what)
  - [Defining Tools](#defining-tools)
  - [Tool Context](#tool-context)
- [Guides](#guides)
  - [Agent with Tools](#agent-with-tools)
  - [Conversation History](#conversation-history)
  - [Streaming](#streaming)
  - [Observable Streaming (SwiftUI)](#observable-streaming-swiftui)
  - [Reasoning Models](#reasoning-models)
  - [Multimodal Input](#multimodal-input)
  - [Audio Output](#audio-output)
  - [Text-to-Speech](#text-to-speech)
  - [Structured Output](#structured-output)
  - [Sub-Agents](#sub-agents)
  - [MCP Tools](#mcp-tools)
  - [Error Handling](#error-handling)
- [Configuration](#configuration)
  - [Agent Configuration](#agent-configuration)
  - [Retry Policy](#retry-policy)
  - [Per-Request Customization](#per-request-customization)
- [LLM Providers](#llm-providers)
  - [Anthropic Messages API](#anthropic-messages-api)
  - [OpenAI Responses API](#openai-responses-api)
  - [ChatGPT Subscription (OAuth)](#chatgpt-subscription-oauth)
  - [Proxy Mode](#proxy-mode)
- [API Reference](#api-reference)
- [Requirements](#requirements)

---

## Quick Start

```swift
import AgentRunKit

let client = OpenAIClient(
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!,
    model: "gpt-4o",
    baseURL: OpenAIClient.openAIBaseURL
)

let agent = Agent<EmptyContext>(client: client, tools: [])
let result = try await agent.run(
    userMessage: "What is the capital of France?",
    context: EmptyContext()
)

print(result.content)
print("Tokens: \(result.totalTokenUsage.total)")
```

---

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Tom-Ryder/AgentRunKit.git", from: "1.0.0")
]
```

```swift
.target(name: "YourApp", dependencies: ["AgentRunKit"])
```

---

## Core Concepts

### When to Use What

| Interface | Use Case |
|-----------|----------|
| `Agent` | Tool-calling workflows. Loops until the model calls `finish`. |
| `AgentStream` | SwiftUI binding. `@Observable` wrapper around `Agent.stream()`. |
| `Chat` | Multi-turn conversations without agent overhead. |
| `client.stream()` | Raw streaming with direct control over deltas. |
| `client.generate()` | Single request/response without streaming. |

> **Note:** `Agent` requires the model to call its `finish` tool. For simple chat, use `Chat` to avoid `maxIterationsReached` errors.

### Defining Tools

Tools use strongly-typed parameters with automatic JSON schema generation:

```swift
struct WeatherParams: Codable, SchemaProviding, Sendable {
    let city: String
    let units: String?
}

struct WeatherResult: Codable, Sendable {
    let temperature: Double
    let condition: String
}

let weatherTool = Tool<WeatherParams, WeatherResult, EmptyContext>(
    name: "get_weather",
    description: "Get current weather for a city",
    executor: { params, _ in
        WeatherResult(temperature: 22.0, condition: "Sunny")
    }
)
```

<details>
<summary><b>Manual Schema Definition</b></summary>

For more control, implement `jsonSchema` explicitly:

```swift
struct ComplexParams: Codable, SchemaProviding, Sendable {
    let items: [String]

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "items": .array(
                    items: .string(description: "Item to process"),
                    description: "List of items"
                )
            ],
            required: ["items"]
        )
    }
}
```

</details>

### Tool Context

Inject dependencies (database, user session, etc.) via a custom context:

```swift
struct AppContext: ToolContext {
    let database: Database
    let currentUserId: String
}

let userTool = Tool<UserParams, UserResult, AppContext>(
    name: "get_user",
    description: "Fetch user from database",
    executor: { params, context in
        let user = try await context.database.fetchUser(id: params.userId)
        return UserResult(name: user.name, email: user.email)
    }
)

let result = try await agent.run(
    userMessage: "Get user 456",
    context: AppContext(database: db, currentUserId: "user_123")
)
```

---

## Guides

### Agent with Tools

```swift
let config = AgentConfiguration(
    maxIterations: 10,
    toolTimeout: .seconds(30),
    systemPrompt: "You are a helpful assistant."
)

let agent = Agent<EmptyContext>(
    client: client,
    tools: [weatherTool, calculatorTool],
    configuration: config
)

let result = try await agent.run(
    userMessage: "What's the weather in Paris?",
    context: EmptyContext()
)

print("Answer: \(result.content)")
print("Iterations: \(result.iterations)")
```

### Conversation History

Each `run()`, `send()`, or `stream()` returns updated history for multi-turn:

```swift
let result1 = try await agent.run(
    userMessage: "Remember the number 42.",
    context: EmptyContext()
)

let result2 = try await agent.run(
    userMessage: "What number did I ask you to remember?",
    history: result1.history,
    context: EmptyContext()
)

print(result2.content)  // "42"
```

<details>
<summary><b>With Chat</b></summary>

```swift
let chat = Chat<EmptyContext>(client: client)

let (response1, history1) = try await chat.send("My name is Alice.")
let (response2, _) = try await chat.send("What's my name?", history: history1)

print(response2.content)  // "Alice"
```

</details>

### Streaming

**Agent/Chat streaming** with `StreamEvent`:

```swift
for try await event in agent.stream(userMessage: "Write a poem", context: EmptyContext(), tokenBudget: 10000) {
    switch event {
    case .delta(let text):
        print(text, terminator: "")
    case .reasoningDelta(let text):
        print("[Thinking] \(text)", terminator: "")
    case .toolCallStarted(let name, _):
        print("\n[Executing \(name)...]")
    case .toolCallCompleted(_, let name, _):
        print("[Completed \(name)]")
    case .subAgentStarted(_, let name):
        print("\n[Sub-agent \(name) starting]")
    case .subAgentEvent(_, _, _):
        break  // child events — inspect recursively if needed
    case .subAgentCompleted(_, let name, let result):
        print("[Sub-agent \(name): \(result.isError ? "error" : "ok")]")
    case .audioData(let data):
        audioPlayer.enqueue(data)  // PCM16 chunk for real-time playback
    case .audioTranscript(let text):
        print(text, terminator: "")
    case .audioFinished(_, _, let data):
        audioPlayer.finalize(data)  // Complete audio buffer
    case .finished(let tokenUsage, _, _, _):
        print("\nTokens: \(tokenUsage.total)")
    }
}
```

<details>
<summary><b>Raw Client Streaming</b></summary>

Use `client.stream()` for lower-level control:

```swift
for try await delta in client.stream(messages: messages, tools: []) {
    switch delta {
    case .content(let text):
        print(text, terminator: "")
    case .reasoning(let text):
        print("[Thinking] \(text)", terminator: "")
    case .toolCallStart(_, _, let name):
        print("\n[Tool: \(name)]")
    case .toolCallDelta(_, _):
        break
    case .audioData(let data):
        audioPlayer.enqueue(data)
    case .audioTranscript(let text):
        print(text, terminator: "")
    case .audioStarted(_, _):
        break
    case .finished(let usage):
        if let usage { print("\nTokens: \(usage.total)") }
    }
}
```

| StreamEvent (Agent/Chat) | StreamDelta (Client) |
|--------------------------|----------------------|
| `.delta(String)` | `.content(String)` |
| `.reasoningDelta(String)` | `.reasoning(String)` |
| `.toolCallStarted(name:id:)` | `.toolCallStart(index:id:name:)` |
| `.toolCallCompleted(id:name:result:)` | `.toolCallDelta(index:arguments:)` |
| `.subAgentStarted(toolCallId:toolName:)` | — |
| `.subAgentEvent(toolCallId:toolName:event:)` | — |
| `.subAgentCompleted(toolCallId:toolName:result:)` | — |
| `.audioData(Data)` | `.audioData(Data)` |
| `.audioTranscript(String)` | `.audioTranscript(String)` |
| `.audioFinished(id:expiresAt:data:)` | `.audioStarted(id:expiresAt:)` |
| `.finished(tokenUsage:content:reason:history:)` | `.finished(usage:)` |

> **Parallel tool execution:** When the LLM calls multiple tools in one turn, they run concurrently. `toolCallCompleted` events fire as each tool finishes — the fastest tool fires first, regardless of dispatch order. Tool results are appended to the LLM context in original dispatch order so the model sees a deterministic conversation.

</details>

### Observable Streaming (SwiftUI)

`AgentStream` is an `@Observable` wrapper that projects `Agent.stream()` into reactive properties for SwiftUI:

```swift
import AgentRunKit

struct ChatView: View {
    let stream: AgentStream<EmptyContext>

    var body: some View {
        VStack {
            ScrollView {
                Text(stream.content)
            }
            ForEach(stream.toolCalls) { toolCall in
                HStack {
                    Text(toolCall.name)
                    switch toolCall.state {
                    case .running: ProgressView()
                    case .completed(let result): Text(result)
                    case .failed(let error): Text(error).foregroundColor(.red)
                    }
                }
            }
            if stream.isStreaming { ProgressView() }
            if let error = stream.error {
                Text("Error: \(error.localizedDescription)")
            }
            Button("Send") {
                stream.send("Hello", context: EmptyContext())
            }
        }
    }
}
```

`send()` cancels any previous stream, resets state, and starts a new stream. All properties update live as tokens arrive. `cancel()` stops the current stream immediately.

Available properties:

| Property | Type | Description |
|----------|------|-------------|
| `content` | `String` | Accumulated text from deltas |
| `reasoning` | `String` | Accumulated reasoning from thinking models |
| `isStreaming` | `Bool` | `true` while a stream is active |
| `error` | `(any Error & Sendable)?` | Error if the stream failed |
| `tokenUsage` | `TokenUsage?` | Token counts after completion |
| `finishReason` | `FinishReason?` | How the agent finished |
| `history` | `[ChatMessage]` | Conversation history for multi-turn |
| `toolCalls` | `[ToolCallInfo]` | Tool call states (`.running`, `.completed`, `.failed`) |

### Reasoning Models

For models with extended thinking:

```swift
// Via Anthropic Messages API (native thinking with Claude)
let client = AnthropicClient(
    apiKey: apiKey,
    model: "claude-sonnet-4-6",
    maxTokens: 16384,
    reasoningConfig: .high  // .xhigh, .high, .medium, .low, .minimal, .none
)

// Via OpenRouter / Chat Completions
let client = OpenAIClient(
    apiKey: apiKey,
    model: "deepseek/deepseek-r1",
    baseURL: OpenAIClient.openRouterBaseURL,
    reasoningConfig: .high
)

// Via OpenAI Responses API (native reasoning with GPT-5.2)
let client = ResponsesAPIClient(
    apiKey: apiKey,
    model: "gpt-5.2",
    baseURL: ResponsesAPIClient.openAIBaseURL,
    reasoningConfig: .medium
)
```

Access reasoning content:

```swift
let response = try await client.generate(messages: messages, tools: [])

if let reasoning = response.reasoning {
    print("Thinking: \(reasoning.content)")
}
print("Answer: \(response.content)")
```

<details>
<summary><b>Fine-Grained Control</b></summary>

```swift
let client = OpenAIClient(
    apiKey: apiKey,
    model: "your-model",
    baseURL: OpenAIClient.openRouterBaseURL,
    reasoningConfig: ReasoningConfig(effort: .high, maxTokens: 16000, exclude: false)
)
```

</details>

<details>
<summary><b>Interleaved Thinking</b></summary>

Reasoning models return opaque reasoning blocks alongside their responses. When the model makes tool calls, these reasoning blocks must be echoed back verbatim on the next request to maintain thinking continuity.

AgentRunKit handles this automatically for all clients:

- **`AnthropicClient`** — Thinking blocks with cryptographic signatures are extracted from streaming events, stored on `AssistantMessage.reasoningDetails`, and echoed back as `thinking` content blocks on subsequent requests. The `anthropic-beta: interleaved-thinking-2025-05-14` header is set automatically when `interleavedThinking: true`.
- **`OpenAIClient`** — `reasoning_details` are extracted from Chat Completions responses, stored on `AssistantMessage`, and included in subsequent requests.
- **`ResponsesAPIClient`** — Reasoning output items (including `encrypted_content` when `store: false`) are captured as raw JSON, accumulated across streaming fragments, and echoed back as input items on the next turn.

No configuration needed — the agent loop preserves reasoning across all tool-calling iterations.

```swift
// Reasoning is preserved across tool-calling turns automatically
for try await event in agent.stream(
    userMessage: "Analyze this data and search for related papers",
    context: EmptyContext()
) {
    switch event {
    case .reasoningDelta(let text):
        print("[Thinking] \(text)", terminator: "")
    case .delta(let text):
        print(text, terminator: "")
    case .finished(let usage, _, _, _):
        print("\nReasoning tokens: \(usage.reasoning)")
    default:
        break
    }
}
```

</details>

### Multimodal Input

Images, audio, video, and PDFs:

```swift
// Image from URL
let message = ChatMessage.user(
    text: "Describe this image",
    imageURL: "https://example.com/image.jpg"
)

// Image from data
let message = ChatMessage.user(
    text: "What's in this photo?",
    imageData: imageData,
    mimeType: "image/jpeg"
)

// Audio (speech to text)
let message = ChatMessage.user(
    text: "Transcribe this:",
    audioData: audioData,
    format: .wav
)

// PDF document
let message = ChatMessage.user([
    .text("Summarize:"),
    .pdf(data: pdfData)
])
```

<details>
<summary><b>Direct Transcription</b></summary>

```swift
let transcript = try await client.transcribe(
    audio: audioData,
    format: .wav,
    model: "whisper-1"
)
```

</details>

### Audio Output

Stream audio responses from models that support `modalities: ["text", "audio"]` (e.g., `gpt-4o-audio-preview`). Enable audio output via `RequestContext.extraFields`:

```swift
let requestContext = RequestContext(extraFields: [
    "modalities": .array([.string("text"), .string("audio")]),
    "audio": .object([
        "voice": .string("alloy"),
        "format": .string("pcm16"),
    ]),
])

for try await event in chat.stream("Tell me a story", context: EmptyContext(), requestContext: requestContext) {
    switch event {
    case .audioData(let chunk):
        audioPlayer.enqueue(chunk)       // PCM16 24kHz mono, stream in real time
    case .audioTranscript(let text):
        print(text, terminator: "")      // Partial transcript of the spoken audio
    case .audioFinished(let id, let expiresAt, let data):
        save(data, id: id)               // Complete accumulated audio buffer
    case .delta(let text):
        print(text, terminator: "")      // Text content (if any)
    case .finished(_, _, _, _):
        break
    default:
        break
    }
}
```

Audio events flow alongside text and tool call events. The streaming pipeline accumulates audio chunks internally and emits `.audioFinished` with the complete buffer after the stream ends. When the model returns audio without text content, the audio transcript is automatically used as the assistant's content in conversation history.

### Text-to-Speech

Convert text to speech using any TTS API. `TTSClient` handles sentence-boundary chunking, bounded-concurrency parallel generation, ordered reassembly, and MP3 concatenation:

```swift
let provider = OpenAITTSProvider(
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!,
    model: "tts-1"
)
let tts = TTSClient(provider: provider)

// Single short text
let audio = try await tts.generate(text: "Hello, world!")

// Stream long text — segments yield in order as they complete
for try await segment in tts.stream(text: articleBody) {
    audioPlayer.enqueue(segment.audio)   // begin playback before all chunks finish
    print("Segment \(segment.index + 1)/\(segment.total)")
}

// Collect all segments into one buffer (MP3-aware concatenation)
let fullAudio = try await tts.generateAll(text: articleBody)
```

Voice, speed, and format are configurable per request:

```swift
let audio = try await tts.generate(
    text: "Speak quickly in a different voice.",
    voice: "nova",
    options: TTSOptions(speed: 1.5, responseFormat: .wav)
)
```

<details>
<summary><b>Custom TTS Provider</b></summary>

Implement `TTSProvider` to use any TTS API:

```swift
struct ElevenLabsProvider: TTSProvider, Sendable {
    let config: TTSProviderConfig

    init() {
        config = TTSProviderConfig(
            maxChunkCharacters: 5000,
            defaultVoice: "rachel",
            defaultFormat: .mp3
        )
    }

    func generate(text: String, voice: String, options: TTSOptions) async throws -> Data {
        // Build and execute your HTTP request here
        // Return raw audio bytes
    }
}

let tts = TTSClient(provider: ElevenLabsProvider(), maxConcurrent: 6)
```

`TTSProviderConfig.maxChunkCharacters` controls how text is split. The chunker uses `NLTokenizer(.sentence)` for sentence-boundary detection, falling back to word and character boundaries for oversized sentences.

</details>

<details>
<summary><b>How Chunking and Concatenation Work</b></summary>

`TTSClient.stream()` internally:

1. Splits text on sentence boundaries respecting `provider.config.maxChunkCharacters`
2. Launches up to `maxConcurrent` parallel generation tasks via `TaskGroup`
3. Buffers out-of-order completions and yields `TTSSegment`s in strict index order
4. Propagates cancellation — cancelling the stream's `Task` cancels all in-flight chunks

`generateAll()` collects all segments from `stream()` and concatenates them. For MP3 output, `MP3Concatenator` strips ID3v2 headers, Xing/Info VBR frames, and ID3v1 tags from interior segments before joining. For other formats, segments are appended directly.

Provider errors are wrapped as `TTSError.chunkFailed(index:total:)` with the underlying `TransportError`. `CancellationError` propagates unwrapped.

</details>

### Structured Output

Request JSON schema-constrained responses:

```swift
struct WeatherReport: Codable, SchemaProviding, Sendable {
    let temperature: Int
    let conditions: String
}

// With client
let response = try await client.generate(
    messages: [.user("Weather in Paris?")],
    tools: [],
    responseFormat: .jsonSchema(WeatherReport.self)
)
let report = try JSONDecoder().decode(WeatherReport.self, from: Data(response.content.utf8))

// With Chat (automatic decoding)
let chat = Chat<EmptyContext>(client: client)
let report: WeatherReport = try await chat.send("Weather in Paris?", returning: WeatherReport.self)
```

### Sub-Agents

Agents can spawn child agents as tools, with automatic depth limiting and token budget enforcement:

```swift
struct ResearchParams: Codable, SchemaProviding, Sendable {
    let query: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

let researchAgent = Agent<SubAgentContext<AppContext>>(
    client: client,
    tools: [webSearchTool, summarizeTool]
)

let researchTool = try SubAgentTool<ResearchParams, AppContext>(
    name: "research",
    description: "Research a topic using web search",
    agent: researchAgent,
    tokenBudget: 5000,
    toolTimeout: nil,                          // nil = no deadline (overrides AgentConfiguration.toolTimeout)
    systemPromptBuilder: { "Research: \($0.query). Be concise." },
    messageBuilder: { $0.query }
)

let orchestrator = Agent<SubAgentContext<AppContext>>(
    client: client,
    tools: [researchTool, writeTool]
)

let ctx = SubAgentContext(inner: AppContext(), maxDepth: 3)
let result = try await orchestrator.run(userMessage: "Write a report on Swift concurrency", context: ctx)
```

`SubAgentContext` wraps your existing context with depth tracking. Each sub-agent call increments depth automatically — if `currentDepth` reaches `maxDepth`, the call throws `AgentError.maxDepthExceeded`. Token budgets are enforced per sub-agent run, preventing any single child from consuming unbounded tokens.

**Timeout:** `toolTimeout: nil` (the default) means the sub-agent runs with no deadline, regardless of the parent's `AgentConfiguration.toolTimeout`. Pass a `Duration` to set a specific timeout for that tool.

**System prompt:** `systemPromptBuilder` is called with the decoded params on each invocation and its return value is used as the child agent's system prompt, overriding whatever the child's `AgentConfiguration` specifies.

**Error propagation:** When a child agent calls `finish` with `reason: "error"`, the parent receives a `ToolResult` with `isError == true`. The orchestrator LLM sees this in its context and can decide whether to retry, fall back, or surface the failure. Custom finish reasons (e.g. `"partial"`) pass through as non-error results.

**Streaming visibility:** When using `agent.stream()`, sub-agent execution is fully observable. The parent stream emits `.subAgentStarted` when a child begins, `.subAgentEvent` for every event the child produces (including nested sub-agents, recursively), and `.subAgentCompleted` when it finishes.

**Inheriting parent messages:** Pass `inheritParentMessages: true` to forward the parent's conversation history (excluding system messages) to the child agent. The child receives the parent's messages as prefill before its task message, enabling prompt-cache hits when multiple parallel sub-agents share the same context. The parent's system message is always stripped — only the child's own system prompt (from `AgentConfiguration` or `systemPromptBuilder`) is used. Defaults to `false`.

<details>
<summary><b>Factory Function</b></summary>

For better type inference at call sites, use the free function:

```swift
let tool: any AnyTool<SubAgentContext<AppContext>> = try subAgentTool(
    name: "research",
    description: "Research a topic",
    agent: researchAgent,
    messageBuilder: { (params: ResearchParams) in params.query }
)
```

</details>

### MCP Tools

Connect to [Model Context Protocol](https://modelcontextprotocol.io) servers and use their tools as if they were native. `MCPSession` manages the full lifecycle — process launch, protocol handshake, tool discovery, and graceful shutdown:

```swift
let config = MCPServerConfiguration(
    name: "filesystem",
    command: "/usr/local/bin/mcp-filesystem",
    arguments: ["--root", "/tmp"]
)

let session = MCPSession(configurations: [config])
let result = try await session.withTools { (tools: [any AnyTool<EmptyContext>]) in
    let agent = Agent<EmptyContext>(client: client, tools: tools)
    return try await agent.run(
        userMessage: "List the files in /tmp",
        context: EmptyContext()
    )
}
```

Multiple servers connect in parallel. Tool names must be unique across servers:

```swift
let session = MCPSession(configurations: [filesystemConfig, gitConfig, databaseConfig])
try await session.withTools { tools in
    // tools contains all tools from all three servers
    let agent = Agent<EmptyContext>(client: client, tools: tools)
    return try await agent.run(userMessage: "...", context: EmptyContext())
}
```

MCP tools work with streaming, sub-agents, and any `ToolContext` — they're indistinguishable from native `Tool<P, O, C>` at the agent level.

<details>
<summary><b>Configuration Options</b></summary>

```swift
let config = MCPServerConfiguration(
    name: "my-server",              // Display name (must be non-empty)
    command: "/path/to/server",     // Executable path (must be non-empty)
    arguments: ["--flag", "value"], // Command-line arguments
    environment: ["API_KEY": key],  // Environment variables (nil = inherit parent)
    workingDirectory: "/tmp",       // Working directory (nil = inherit parent)
    initializationTimeout: .seconds(30),  // Handshake + tool discovery timeout
    toolCallTimeout: .seconds(60)         // Per-tool-call timeout
)
```

</details>

<details>
<summary><b>Error Handling</b></summary>

MCP errors are surfaced as `MCPError`:

```swift
do {
    try await session.withTools { tools in ... }
} catch let error as MCPError {
    switch error {
    case .connectionFailed(let reason):
        print("Server failed to start: \(reason)")
    case .protocolVersionMismatch(let requested, let supported):
        print("Version mismatch: wanted \(requested), got \(supported)")
    case .requestTimeout(let method):
        print("RPC \(method) timed out")
    case .duplicateToolName(let tool, let servers):
        print("Tool '\(tool)' exists on multiple servers: \(servers)")
    case .jsonRPCError(let code, let message):
        print("Server error \(code): \(message)")
    case .transportClosed:
        print("Connection lost")
    default:
        print("MCP error: \(error)")
    }
}
```

When an MCP tool fails during agent execution, the error is wrapped as `AgentError.toolExecutionFailed` and fed back to the LLM for recovery, just like native tool errors.

</details>

<details>
<summary><b>Custom Transport</b></summary>

`MCPTransport` is a protocol — implement it for non-stdio transports (HTTP/SSE, WebSocket, in-process):

```swift
public protocol MCPTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func messages() -> AsyncThrowingStream<Data, Error>
}
```

Inject a custom transport via the internal initializer:

```swift
let session = MCPSession(
    configurations: configs,
    transportFactory: { config in MyCustomTransport(config: config) }
)
```

</details>

### Error Handling

```swift
do {
    let result = try await agent.run(userMessage: "...", context: EmptyContext())
} catch let error as AgentError {
    switch error {
    case .maxIterationsReached(let count):
        print("Didn't finish in \(count) iterations")
    case .toolTimeout(let tool):
        print("Tool '\(tool)' timed out")
    case .toolNotFound(let name):
        print("Unknown tool: \(name)")
    case .toolExecutionFailed(let tool, let message):
        print("Tool '\(tool)' failed: \(message)")
    case .maxDepthExceeded(let depth):
        print("Sub-agent nesting too deep at level \(depth)")
    case .tokenBudgetExceeded(let budget, let used):
        print("Token budget \(budget) exceeded (used \(used))")
    case .llmError(let transport):
        switch transport {
        case .rateLimited(let retryAfter):
            print("Rate limited. Retry: \(retryAfter?.description ?? "unknown")")
        case .httpError(let status, let body):
            print("HTTP \(status): \(body)")
        default:
            print("Transport: \(transport)")
        }
    default:
        print("Error: \(error)")
    }
}
```

> Tool errors are automatically fed back to the LLM for recovery via `AgentError.feedbackMessage`.

---

## Configuration

### Agent Configuration

```swift
let config = AgentConfiguration(
    maxIterations: 10,          // Max tool-calling rounds
    maxMessages: 50,            // Context truncation limit
    toolTimeout: .seconds(30),  // Per-tool timeout
    systemPrompt: "You are a helpful assistant."
)
```

### Retry Policy

```swift
let client = OpenAIClient(
    apiKey: apiKey,
    model: "gpt-4o",
    baseURL: OpenAIClient.openAIBaseURL,
    retryPolicy: RetryPolicy(
        maxAttempts: 5,
        baseDelay: .seconds(2),
        maxDelay: .seconds(60),
        streamStallTimeout: .seconds(30)  // Detect silently dropped SSE connections
    )
)
```

### Per-Request Customization

`RequestContext` injects arbitrary fields into the HTTP request body and provides access to response headers. Pass it to any Agent, Chat, or client method:

```swift
let requestContext = RequestContext(
    extraFields: [
        "web_search_options": .object(["search_context_size": .string("high")]),
        "provider": .object(["order": .array([.string("cerebras")])]),
    ],
    onResponse: { response in
        print(response.value(forHTTPHeaderField: "X-Request-Id") ?? "")
    }
)

// Agent
let result = try await agent.run(
    userMessage: "Search the web for latest news",
    context: myContext,
    requestContext: requestContext
)

// Streaming
for try await event in agent.stream(
    userMessage: "Summarize recent events",
    context: myContext,
    requestContext: requestContext
) { ... }

// Chat
let (response, history) = try await chat.send("Hello", requestContext: requestContext)
```

---

## LLM Providers

### Chat Completions (`OpenAIClient`)

Works with any OpenAI-compatible API:

| Provider | Base URL |
|----------|----------|
| OpenAI | `OpenAIClient.openAIBaseURL` |
| OpenRouter | `OpenAIClient.openRouterBaseURL` |
| Groq | `OpenAIClient.groqBaseURL` |
| Together | `OpenAIClient.togetherBaseURL` |
| Ollama | `OpenAIClient.ollamaBaseURL` |

```swift
// OpenRouter
let client = OpenAIClient(
    apiKey: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]!,
    model: "anthropic/claude-sonnet-4",
    baseURL: OpenAIClient.openRouterBaseURL
)

// Local Ollama
let client = OpenAIClient(
    apiKey: "ollama",
    model: "llama3.2",
    baseURL: OpenAIClient.ollamaBaseURL
)
```

### Anthropic Messages API

`AnthropicClient` speaks the [Anthropic Messages API](https://docs.anthropic.com/en/api/messages) natively — extended thinking, interleaved thinking, and streaming with full content block lifecycle.

```swift
let client = AnthropicClient(
    apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!,
    model: "claude-sonnet-4-6",
    maxTokens: 16384,
    reasoningConfig: .high,
    interleavedThinking: true
)

let agent = Agent<EmptyContext>(client: client, tools: [myTool])
let result = try await agent.run(userMessage: "Analyze this problem", context: EmptyContext())
```

Both `Agent` and `Chat` work identically with `AnthropicClient` — just swap the client at construction time. Streaming, tool calling, sub-agents, and MCP tools all work unchanged.

<details>
<summary><b>Prompt Caching</b></summary>

Enable server-side caching of system prompts and tool definitions with `cachingEnabled`. Anthropic caches content blocks marked with `cache_control: {"type": "ephemeral"}` for 5 minutes (refreshed on use), giving a 90% input token discount on cache hits — significant savings in agent loops where the system prompt and tools are resent every iteration.

```swift
let client = AnthropicClient(
    apiKey: apiKey,
    model: "claude-sonnet-4-6",
    maxTokens: 16384,
    cachingEnabled: true
)
```

When enabled, `buildRequest` marks the last system block and the last tool definition with `cache_control`. Cache token usage is reported on `TokenUsage`:

```swift
let result = try await agent.run(userMessage: "...", context: EmptyContext())
if let cacheRead = result.totalTokenUsage.cacheRead {
    print("Cache read tokens: \(cacheRead)")
}
if let cacheWrite = result.totalTokenUsage.cacheWrite {
    print("Cache write tokens: \(cacheWrite)")
}
```

</details>

<details>
<summary><b>Extended Thinking</b></summary>

Extended thinking is configured via `ReasoningConfig`. Effort levels map to token budgets automatically:

```swift
// Effort-based (recommended)
let client = AnthropicClient(
    apiKey: apiKey,
    model: "claude-sonnet-4-6",
    maxTokens: 16384,
    reasoningConfig: .high  // .xhigh, .high, .medium, .low, .minimal
)

// Explicit budget
let client = AnthropicClient(
    apiKey: apiKey,
    model: "claude-sonnet-4-6",
    maxTokens: 65536,
    reasoningConfig: .budget(10000)
)
```

When `interleavedThinking` is `true` (the default), the client sets the `anthropic-beta: interleaved-thinking-2025-05-14` header and allows thinking budgets to exceed `maxTokens`. When `false`, the budget is capped to `maxTokens - 1` per Anthropic's requirements.

</details>

<details>
<summary><b>Custom Base URL</b></summary>

Point at a proxy, gateway, or alternative endpoint:

```swift
let client = AnthropicClient(
    apiKey: apiKey,
    model: "claude-sonnet-4-6",
    baseURL: URL(string: "https://api.myproxy.com/v1")!
)
```

</details>

<details>
<summary><b>Additional Headers</b></summary>

Inject custom headers per request. Core headers (`x-api-key`, `anthropic-version`, `anthropic-beta`) cannot be overridden:

```swift
let client = AnthropicClient(
    apiKey: apiKey,
    model: "claude-sonnet-4-6",
    additionalHeaders: { ["X-Request-Source": "my-app"] }
)
```

The header closure is evaluated per request, enabling dynamic values.

</details>

### OpenAI Responses API

`ResponsesAPIClient` speaks OpenAI's [Responses API](https://platform.openai.com/docs/api-reference/responses) — a newer endpoint with native support for reasoning models, server-side conversation state, and structured tool calling.

```swift
let client = ResponsesAPIClient(
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!,
    model: "gpt-5.2",
    baseURL: ResponsesAPIClient.openAIBaseURL,
    reasoningConfig: .medium
)

let agent = Agent<EmptyContext>(client: client, tools: [myTool])
let result = try await agent.run(userMessage: "Solve this problem", context: EmptyContext())
```

Both `Agent` and `Chat` work identically with either client — just swap the client at construction time.

<details>
<summary><b>Server-Side Conversation State</b></summary>

When `store: true` (the default), `ResponsesAPIClient` automatically tracks `previous_response_id` across requests. On subsequent turns, only new messages are sent — the server reconstructs the full conversation from its stored state. This reduces request size and latency on long conversations.

This is transparent to the agent loop — the same `[ChatMessage]` history API works regardless.

</details>

### ChatGPT Subscription (OAuth)

Use your ChatGPT Plus or Pro subscription instead of API credits. `ResponsesAPIClient` works with the ChatGPT backend endpoint using OAuth tokens from [Codex CLI](https://github.com/openai/codex):

```swift
// 1. Read stored OAuth tokens (after authenticating via Codex CLI)
let authData = try Data(contentsOf: homeDir.appendingPathComponent(".codex/auth.json"))
let auth = try JSONDecoder().decode(CodexAuth.self, from: authData)

// 2. Create client pointing at ChatGPT backend
let client = ResponsesAPIClient(
    model: "gpt-5.2",
    maxOutputTokens: nil,          // not supported on this endpoint
    baseURL: ResponsesAPIClient.chatGPTBaseURL,
    additionalHeaders: {
        [
            "Authorization": "Bearer \(auth.tokens.accessToken)",
            "ChatGPT-Account-ID": auth.tokens.accountId,
        ]
    },
    store: false                   // required for ChatGPT backend
)

// 3. Use it like any other client — streaming only
let agent = Agent<EmptyContext>(client: client, tools: [myTool])
for try await event in agent.stream(userMessage: "What is 17 + 25?", context: EmptyContext()) {
    // ...
}
```

The ChatGPT backend enforces specific constraints:

| Constraint | Detail |
|-----------|--------|
| `store` | Must be `false` |
| `stream` | Must be `true` — use `Agent.stream()` or `Chat.stream()`, not `.run()` or `.send()` |
| `max_output_tokens` | Not supported — set `maxOutputTokens: nil` |
| `instructions` | Required — always provide a system prompt |

Reasoning models (GPT-5.2, GPT-5.2-codex) work fully, including interleaved thinking with opaque reasoning block echo-back across tool-calling turns.

### Proxy Mode

For backends that handle auth and model selection server-side:

```swift
let client = OpenAIClient.proxy(
    baseURL: URL(string: "https://api.myapp.com/v1/ai")!,
    additionalHeaders: { ["Authorization": "Bearer \(userToken)"] }
)
```

The header closure is evaluated per-request, enabling rotating tokens or dynamic auth.

Useful for iOS apps where:
- Backend manages LLM API keys (security)
- Backend selects models (A/B testing, upgrades without app updates)
- Backend injects context or tracks usage

The `proxy()` factory omits `Authorization: Bearer` and `model` from requests.

---

## API Reference

<details>
<summary><b>Core Types</b></summary>

| Type | Description |
|------|-------------|
| `Agent<C>` | Main agent loop coordinator |
| `AgentStream<C>` | `@Observable` wrapper for SwiftUI streaming |
| `AgentConfiguration` | Agent behavior settings |
| `AgentResult` | Final result with content and token usage |
| `Chat<C>` | Lightweight multi-turn chat interface |
| `StreamEvent` | Streaming event types |
| `ToolCallInfo` | Tool call state (`.running`, `.completed`, `.failed`) |

</details>

<details>
<summary><b>Tool Types</b></summary>

| Type | Description |
|------|-------------|
| `Tool<P, O, C>` | Type-safe tool definition |
| `AnyTool` | Type-erased tool protocol |
| `ToolContext` | Protocol for dependency injection |
| `EmptyContext` | Null context for stateless tools |
| `ToolResult` | Tool execution result (`content: String`, `isError: Bool`) |
| `SubAgentTool<P, C>` | Tool that delegates to a child agent |
| `SubAgentContext<C>` | Context wrapper with depth tracking |

</details>

<details>
<summary><b>Schema Types</b></summary>

| Type | Description |
|------|-------------|
| `JSONSchema` | JSON Schema representation |
| `SchemaProviding` | Protocol for automatic schema generation |
| `SchemaDecoder` | Automatic schema inference from Decodable |

</details>

<details>
<summary><b>LLM Types</b></summary>

| Type | Description |
|------|-------------|
| `LLMClient` | Protocol for LLM implementations |
| `AnthropicClient` | Anthropic Messages API client (Claude Sonnet, Opus, Haiku) |
| `OpenAIClient` | Chat Completions client (OpenAI, OpenRouter, Groq, etc.) |
| `ResponsesAPIClient` | OpenAI Responses API client (GPT-5.2, GPT-5.2-codex) |
| `ResponseFormat` | Structured output configuration |
| `RetryPolicy` | Exponential backoff settings |
| `ReasoningConfig` | Reasoning effort for thinking models |
| `RequestContext` | Per-request extra fields and callbacks |
| `JSONValue` | Type-safe JSON value enum |

</details>

<details>
<summary><b>Message Types</b></summary>

| Type | Description |
|------|-------------|
| `ChatMessage` | Conversation message enum |
| `AssistantMessage` | LLM response with tool calls and reasoning |
| `TokenUsage` | Token accounting (input, output, reasoning, cacheRead, cacheWrite, total) |
| `ContentPart` | Multimodal content element |
| `ReasoningContent` | Reasoning/thinking content |

</details>

<details>
<summary><b>TTS Types</b></summary>

| Type | Description |
|------|-------------|
| `TTSClient<P>` | Text-to-speech orchestrator with chunking and concurrency |
| `TTSProvider` | Protocol for TTS service implementations |
| `TTSProviderConfig` | Provider constraints (max chunk size, default voice/format) |
| `TTSOptions` | Per-request options (speed, format override) |
| `TTSAudioFormat` | Audio format enum (mp3, opus, aac, flac, wav, pcm) |
| `TTSSegment` | Ordered audio chunk with index and total count |
| `TTSError` | TTS-specific errors (emptyText, chunkFailed, invalidConfiguration) |
| `OpenAITTSProvider` | Built-in provider for OpenAI's `/audio/speech` endpoint |
| `MP3Concatenator` | MP3-aware segment joiner (strips ID3/Xing metadata) |
| `SentenceChunker` | NLTokenizer-based text splitter |

</details>

<details>
<summary><b>MCP Types</b></summary>

| Type | Description |
|------|-------------|
| `MCPSession` | Scoped MCP server lifecycle manager (`withTools` pattern) |
| `MCPServerConfiguration` | Server command, arguments, environment, and timeouts |
| `MCPClient` | Actor managing a single MCP server connection |
| `MCPTool<C>` | `AnyTool` adapter that delegates `execute` to an MCP server |
| `MCPToolInfo` | Tool name, description, and input schema from `tools/list` |
| `MCPContent` | MCP content types: text, image, audio, resource link, embedded resource |
| `MCPCallResult` | Tool call result with content array and optional structured content |
| `MCPError` | MCP-specific errors (connection, timeout, protocol, transport) |
| `MCPTransport` | Protocol for MCP transport implementations |
| `StdioMCPTransport` | Stdio transport (macOS only) — launches process, communicates via stdin/stdout |

</details>

<details>
<summary><b>Error Types</b></summary>

| Type | Description |
|------|-------------|
| `AgentError` | Typed agent framework errors |
| `TransportError` | HTTP and network errors |
| `MCPError` | MCP connection, protocol, and transport errors |
| `TTSError` | TTS chunk and configuration errors |

</details>

<details>
<summary><b>Custom LLM Client</b></summary>

Implement `LLMClient` for non-OpenAI-compatible providers:

```swift
public protocol LLMClient: Sendable {
    func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?
    ) async throws -> AssistantMessage

    func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error>
}
```

</details>

---

## Requirements

| Platform | Version |
|----------|---------|
| iOS | 18.0+ |
| macOS | 15.0+ |
| Swift | 6.0+ |
| Xcode | 16+ |

---

## License

MIT License. See [LICENSE](LICENSE) for details.
