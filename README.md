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

- **Zero external dependencies** - Foundation only
- **Modern Swift 6** - Full `Sendable` compliance, async/await, structured concurrency
- **Type-safe tools** - Generic `Tool<P, O, C>` with automatic JSON schema generation
- **Multi-provider** - OpenAI, OpenRouter, Groq, Together, Ollama (any OpenAI-compatible API)
- **Streaming** - First-class `AsyncThrowingStream` support with progress events
- **Production-ready** - Retry with backoff, timeout handling, proper error propagation

## Features

- **Agent Loop** - Generate → execute tools → repeat until completion
- **Type-Safe Tools** - Define tools with `Codable` parameters and automatic schema inference
- **Multi-Provider Support** - OpenAI, OpenRouter, Groq, Together, Ollama
- **Streaming** - Real-time token streaming with `StreamEvent` callbacks
- **Multimodal** - Images, audio, video, and PDF (base64; images also support URLs)
- **Structured Output** - JSON schema-constrained responses
- **Retry with Backoff** - Automatic retry on transient failures and rate limits
- **Cancellation** - Proper Swift concurrency cancellation support
- **Timeout** - Configurable per-tool execution timeout
- **Token Tracking** - Aggregated token usage across iterations with overflow protection

## Installation

Add AgentRunKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Tom-Ryder/AgentRunKit.git", from: "1.0.0")
]
```

Then add it to your target:

```swift
.target(name: "YourApp", dependencies: ["AgentRunKit"])
```

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
print("Tokens used: \(result.totalTokenUsage.total)")
```

## When to Use What

| Interface | Use Case |
|-----------|----------|
| `Agent` | Tool-calling workflows. Injects a `finish` tool and loops until the model calls it. |
| `Chat` | Simple multi-turn conversations without the agent loop overhead. |
| `client.stream()` | Raw streaming when you need direct control over deltas. |
| `client.generate()` | Single request/response without streaming. |

**Important:** `Agent` requires the model to call its `finish` tool to complete. If you're doing simple chat without tools, use `Chat` or the client directly to avoid `maxIterationsReached` errors.

## Defining Tools

Tools are defined with strongly-typed parameters and outputs. The framework handles JSON encoding/decoding automatically.

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
        // Your implementation here
        WeatherResult(temperature: 22.0, condition: "Sunny")
    }
)
```

### Automatic Schema Generation

Types conforming to `Codable` and `SchemaProviding` get automatic JSON schema generation:

```swift
struct SearchParams: Codable, SchemaProviding, Sendable {
    let query: String
    let maxResults: Int?
    // JSON schema is auto-generated from the Codable structure
}
```

### Manual Schema Definition

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

## Agent with Tools

A complete agent that invokes tools and iterates until completion:

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
print("Finish reason: \(result.finishReason)")
```

## Conversation History

Pass conversation history for multi-turn interactions. Each `run()`, `send()`, or `stream()` returns the updated history.

```swift
// First turn
let result1 = try await agent.run(
    userMessage: "Remember the number 42.",
    context: EmptyContext()
)

// Second turn - pass history from previous result
let result2 = try await agent.run(
    userMessage: "What number did I ask you to remember?",
    history: result1.history,
    context: EmptyContext()
)

print(result2.content)  // "42"
```

Works the same with `Chat`:

```swift
let chat = Chat<EmptyContext>(client: client)

let (response1, history1) = try await chat.send("My name is Alice.")
let (response2, _) = try await chat.send("What's my name?", history: history1)

print(response2.content)  // "Alice"
```

And with streaming:

```swift
var history: [ChatMessage] = []
for try await event in agent.stream(
    userMessage: "Continue our conversation",
    history: history,
    context: EmptyContext()
) {
    if case let .finished(_, _, _, newHistory) = event {
        history = newHistory
    }
}
```

## Tool Context

Inject app-specific dependencies (database, user session, etc.) via a custom context:

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

let context = AppContext(database: db, currentUserId: "user_123")
let result = try await agent.run(userMessage: "Get user 456", context: context)
```

## Streaming

### Agent Streaming (StreamEvent)

Use `agent.stream()` or `chat.stream()` for high-level streaming with tool execution:

```swift
for try await event in agent.stream(userMessage: "Write a poem", context: EmptyContext()) {
    switch event {
    case .delta(let text):
        print(text, terminator: "")

    case .reasoningDelta(let text):
        print("[Thinking] \(text)", terminator: "")

    case .toolCallStarted(let name, let id):
        print("\n[Executing \(name)...]")

    case .toolCallCompleted(let id, let name, let result):
        print("[Completed \(name)]")

    case .finished(let tokenUsage, let content, let reason, let history):
        print("\nDone. Tokens: \(tokenUsage.total)")
    }
}
```

### Client Streaming (StreamDelta)

Use `client.stream()` for raw streaming without agent overhead:

```swift
for try await delta in client.stream(messages: messages, tools: []) {
    switch delta {
    case .content(let text):
        print(text, terminator: "")

    case .reasoning(let text):
        print("[Thinking] \(text)", terminator: "")

    case .toolCallStart(let index, let id, let name):
        print("\n[Tool: \(name)]")

    case .toolCallDelta(let index, let arguments):
        // Accumulate tool arguments
        break

    case .finished(let usage):
        if let usage {
            print("\nTokens: \(usage.total)")
        }
    }
}
```

### StreamEvent vs StreamDelta

| StreamEvent (Agent/Chat) | StreamDelta (Client) |
|--------------------------|----------------------|
| `.delta(String)` | `.content(String)` |
| `.reasoningDelta(String)` | `.reasoning(String)` |
| `.toolCallStarted(name:id:)` | `.toolCallStart(index:id:name:)` |
| `.toolCallCompleted(id:name:result:)` | `.toolCallDelta(index:arguments:)` |
| `.finished(tokenUsage:content:reason:history:)` | `.finished(usage:)` |

## Reasoning

For models that support extended thinking, configure reasoning behavior:

```swift
let client = OpenAIClient(
    apiKey: apiKey,
    model: "your-model",
    baseURL: OpenAIClient.openRouterBaseURL,
    reasoningConfig: .high  // .xhigh, .high, .medium, .low, .minimal, .none
)

// Or with fine-grained control
let client = OpenAIClient(
    apiKey: apiKey,
    model: "your-model",
    baseURL: OpenAIClient.openRouterBaseURL,
    reasoningConfig: ReasoningConfig(effort: .high, maxTokens: 16000, exclude: false)
)
```

### Non-Streaming

Access reasoning content from responses:

```swift
let response = try await client.generate(messages: messages, tools: [])

if let reasoning = response.reasoning {
    print("Thinking: \(reasoning.content)")
}
print("Answer: \(response.content)")
```

### Streaming

Receive reasoning deltas in real-time:

```swift
for try await event in agent.stream(userMessage: "Solve this problem", context: EmptyContext()) {
    switch event {
    case .reasoningDelta(let text):
        // Model's thinking process
        print(text, terminator: "")
    case .delta(let text):
        // Final answer
        print(text, terminator: "")
    case .finished(_, _, _, let history):
        // Reasoning is preserved in history for multi-turn
        break
    default:
        break
    }
}
```

## Configuration

### Agent Configuration

```swift
let config = AgentConfiguration(
    maxIterations: 10,          // Maximum tool-calling rounds
    maxMessages: 50,            // Truncate context to 50 messages
    toolTimeout: .seconds(30),  // Per-tool timeout
    systemPrompt: "You are a helpful assistant."
)
```

Context truncation (`maxMessages`) removes the oldest messages when the conversation exceeds the limit. The system prompt is always preserved, and tool call/result pairs are kept together to maintain conversation coherence.

### Retry Policy

```swift
let client = OpenAIClient(
    apiKey: apiKey,
    model: "gpt-4o",
    baseURL: OpenAIClient.openAIBaseURL,
    retryPolicy: RetryPolicy(
        maxAttempts: 5,
        baseDelay: .seconds(2),
        maxDelay: .seconds(60)
    )
)
```

### Per-Request Customization

Inject extra fields into the request body and access response headers via `RequestContext`:

```swift
var conversationId: String?

let context = RequestContext(
    extraFields: conversationId.map {
        ["conversationId": .string($0), "conversationType": .string("coaching")]
    } ?? [:],
    onResponse: { response in
        if let id = response.value(forHTTPHeaderField: "X-Conversation-Id") {
            conversationId = id
        }
    }
)

let stream = client.stream(messages: messages, tools: [], context: context)
```

`extraFields` accepts any JSON structure via the type-safe `JSONValue` enum:

```swift
let context = RequestContext(extraFields: [
    "temperature": .double(0.7),
    "metadata": .object(["user_id": .string("123")]),
    "stop": .array([.string("END"), .string("STOP")])
])
```

## LLM Providers

AgentRunKit works with any OpenAI-compatible API:

| Provider | Base URL | Notes |
|----------|----------|-------|
| OpenAI | `OpenAIClient.openAIBaseURL` | Direct OpenAI API |
| OpenRouter | `OpenAIClient.openRouterBaseURL` | Multi-model gateway |
| Groq | `OpenAIClient.groqBaseURL` | Fast inference |
| Together | `OpenAIClient.togetherBaseURL` | Open models |
| Ollama | `OpenAIClient.ollamaBaseURL` | Local models |

```swift
// OpenRouter (access to many models)
let openRouter = OpenAIClient(
    apiKey: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]!,
    model: "anthropic/claude-sonnet-4",
    baseURL: OpenAIClient.openRouterBaseURL
)

// Local Ollama
let ollama = OpenAIClient(
    apiKey: "ollama",
    model: "llama3.2",
    baseURL: OpenAIClient.ollamaBaseURL
)

// Custom endpoint
let custom = OpenAIClient(
    apiKey: "your-key",
    model: "your-model",
    baseURL: URL(string: "https://your-api.com/v1")!
)

// Enterprise proxy with custom headers
let proxy = OpenAIClient(
    apiKey: "your-key",
    model: "gpt-4o",
    baseURL: URL(string: "https://proxy.internal.corp/v1")!,
    chatCompletionPath: "llm/chat",
    additionalHeaders: ["X-User-Id": "alice", "X-Team": "platform"]
)
```

## Multimodal Input

Send images, audio, video, and PDFs. For OpenRouter speech-to-text, use model `mistralai/voxtral-small-24b-2507`.

```swift
// Image from URL
let message = ChatMessage.user(
    text: "Describe this image",
    imageURL: "https://example.com/image.jpg"
)

// Image from data
let imageData = try Data(contentsOf: localImageURL)
let message = ChatMessage.user(
    text: "What's in this photo?",
    imageData: imageData,
    mimeType: "image/jpeg"
)

// Multiple content parts
let message = ChatMessage.user([
    .text("Compare these images:"),
    .image(url: "https://example.com/a.jpg"),
    .image(url: "https://example.com/b.jpg")
])

// Audio (speech to text)
let audioData = try Data(contentsOf: audioURL)
let message = ChatMessage.user(
    text: "Transcribe this audio:",
    audioData: audioData,
    format: .wav
)

// PDF document
let pdfData = try Data(contentsOf: pdfURL)
let message = ChatMessage.user([
    .text("Summarize this document:"),
    .pdf(data: pdfData)
])
```

Direct transcription via `/audio/transcriptions`:

```swift
let transcript = try await client.transcribe(
    audio: audioData,
    format: .wav,
    model: "whisper-1"
)

let transcript = try await client.transcribe(
    audioFileURL: audioURL,
    format: .wav,
    model: "whisper-1"
)
```

## Structured Output

Request JSON schema-constrained responses:

```swift
struct WeatherReport: Codable, SchemaProviding, Sendable {
    let temperature: Int
    let conditions: String
    let humidity: Int
}

let response = try await client.generate(
    messages: [.user("What's the weather in Paris?")],
    tools: [],
    responseFormat: .jsonSchema(WeatherReport.self)
)

let report = try JSONDecoder().decode(
    WeatherReport.self,
    from: Data(response.content.utf8)
)
```

Or use the `Chat` interface for automatic decoding:

```swift
let chat = Chat<EmptyContext>(client: client)
let report: WeatherReport = try await chat.send(
    "What's the weather in Paris?",
    returning: WeatherReport.self
)
```

## Error Handling

AgentRunKit provides typed errors for proper handling:

```swift
do {
    let result = try await agent.run(userMessage: "...", context: EmptyContext())
} catch let error as AgentError {
    switch error {
    case .maxIterationsReached(let count):
        print("Agent didn't finish in \(count) iterations")

    case .toolTimeout(let tool):
        print("Tool '\(tool)' timed out")

    case .toolNotFound(let name):
        print("Unknown tool: \(name)")

    case .toolExecutionFailed(let tool, let message):
        print("Tool '\(tool)' failed: \(message)")

    case .llmError(let transport):
        switch transport {
        case .rateLimited(let retryAfter):
            print("Rate limited. Retry after: \(retryAfter?.description ?? "unknown")")
        case .httpError(let status, let body):
            print("HTTP \(status): \(body)")
        default:
            print("Transport error: \(transport)")
        }

    default:
        print("Error: \(error.localizedDescription)")
    }
}
```

Tool execution errors are automatically fed back to the LLM for recovery. Each `AgentError` has a `feedbackMessage` property suitable for sending to the model.

## Custom LLM Clients

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

## API Reference

### Core Types

| Type | Description |
|------|-------------|
| `Agent<C>` | Main agent loop coordinator |
| `AgentConfiguration` | Agent behavior settings |
| `AgentResult` | Final result with content and token usage |
| `Chat<C>` | Lightweight multi-turn chat interface |
| `StreamEvent` | Streaming event types |

### Tool Types

| Type | Description |
|------|-------------|
| `Tool<P, O, C>` | Type-safe tool definition |
| `AnyTool` | Type-erased tool protocol |
| `ToolContext` | Protocol for dependency injection |
| `EmptyContext` | Null context for stateless tools |
| `ToolResult` | Tool execution result |

### Schema Types

| Type | Description |
|------|-------------|
| `JSONSchema` | JSON Schema representation |
| `SchemaProviding` | Protocol for automatic schema generation |
| `SchemaDecoder` | Automatic schema inference from Decodable |

### LLM Types

| Type | Description |
|------|-------------|
| `LLMClient` | Protocol for LLM implementations |
| `OpenAIClient` | OpenAI-compatible client |
| `ResponseFormat` | Structured output configuration |
| `RetryPolicy` | Exponential backoff settings |
| `ReasoningConfig` | Reasoning effort configuration for thinking models |
| `RequestContext` | Per-request extra fields and response callback |
| `JSONValue` | Type-safe JSON value (string, int, double, bool, null, array, object) |

### Message Types

| Type | Description |
|------|-------------|
| `ChatMessage` | Conversation message enum |
| `AssistantMessage` | LLM response with tool calls and reasoning |
| `TokenUsage` | Token accounting (`.input`, `.output`, `.reasoning`, `.total`) |
| `ContentPart` | Multimodal content element |
| `ReasoningContent` | Reasoning/thinking content from models |

### Error Types

| Type | Description |
|------|-------------|
| `AgentError` | Typed agent framework errors |
| `TransportError` | HTTP and network errors |

## Requirements

| Platform | Minimum Version |
|----------|-----------------|
| iOS | 18.0+ |
| macOS | 15.0+ |
| Swift | 6.0+ |
| Xcode | 16+ |

## License

MIT License. See [LICENSE](LICENSE) for details.
