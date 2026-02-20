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
  <b>Zero dependencies</b> · <b>Full Sendable</b> · <b>Async/await</b> · <b>Multi-provider</b> · <b>Production-ready</b>
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
  - [Reasoning Models](#reasoning-models)
  - [Multimodal Input](#multimodal-input)
  - [Structured Output](#structured-output)
  - [Sub-Agents](#sub-agents)
  - [Error Handling](#error-handling)
- [Configuration](#configuration)
  - [Agent Configuration](#agent-configuration)
  - [Retry Policy](#retry-policy)
  - [Per-Request Customization](#per-request-customization)
- [LLM Providers](#llm-providers)
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
for try await event in agent.stream(userMessage: "Write a poem", context: EmptyContext()) {
    switch event {
    case .delta(let text):
        print(text, terminator: "")
    case .reasoningDelta(let text):
        print("[Thinking] \(text)", terminator: "")
    case .toolCallStarted(let name, _):
        print("\n[Executing \(name)...]")
    case .toolCallCompleted(_, let name, _):
        print("[Completed \(name)]")
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
| `.finished(tokenUsage:content:reason:history:)` | `.finished(usage:)` |

</details>

### Reasoning Models

For models with extended thinking:

```swift
let client = OpenAIClient(
    apiKey: apiKey,
    model: "deepseek/deepseek-r1",
    baseURL: OpenAIClient.openRouterBaseURL,
    reasoningConfig: .high  // .xhigh, .high, .medium, .low, .minimal, .none
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

Models like Claude and DeepSeek return opaque `reasoning_details` blocks alongside their responses. These must be echoed back verbatim on subsequent requests to maintain thinking continuity across tool-calling turns.

AgentRunKit handles this automatically — `reasoning_details` are extracted from each response, stored on `AssistantMessage`, and included in the next request. No configuration needed.

```swift
// reasoning_details are preserved across tool-calling turns automatically
let result = try await agent.run(
    userMessage: "Analyze this data and search for related papers",
    context: EmptyContext()
)

// Access reasoning details if needed
for message in result.history {
    if case .assistant(let msg) = message, let details = msg.reasoningDetails {
        print("Reasoning blocks: \(details.count)")
    }
}
```

Keys inside `reasoning_details` are preserved verbatim (not mangled by `camelCase` conversion), ensuring the opaque contract with the provider is maintained.

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
        maxDelay: .seconds(60)
    )
)
```

### Per-Request Customization

Inject extra fields and access response headers:

```swift
let context = RequestContext(
    extraFields: [
        "temperature": .double(0.7),
        "metadata": .object(["user_id": .string("123")])
    ],
    onResponse: { response in
        print(response.value(forHTTPHeaderField: "X-Request-Id") ?? "")
    }
)

let stream = client.stream(messages: messages, tools: [], context: context)
```

---

## LLM Providers

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

### Proxy Mode

For backends that handle auth and model selection server-side:

```swift
let client = OpenAIClient.proxy(
    baseURL: URL(string: "https://api.myapp.com/v1/ai")!,
    additionalHeaders: ["Authorization": "Bearer \(userToken)"]
)
```

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
| `AgentConfiguration` | Agent behavior settings |
| `AgentResult` | Final result with content and token usage |
| `Chat<C>` | Lightweight multi-turn chat interface |
| `StreamEvent` | Streaming event types |

</details>

<details>
<summary><b>Tool Types</b></summary>

| Type | Description |
|------|-------------|
| `Tool<P, O, C>` | Type-safe tool definition |
| `AnyTool` | Type-erased tool protocol |
| `ToolContext` | Protocol for dependency injection |
| `EmptyContext` | Null context for stateless tools |
| `ToolResult` | Tool execution result |
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
| `OpenAIClient` | OpenAI-compatible client |
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
| `TokenUsage` | Token accounting (input, output, reasoning, total) |
| `ContentPart` | Multimodal content element |
| `ReasoningContent` | Reasoning/thinking content |

</details>

<details>
<summary><b>Error Types</b></summary>

| Type | Description |
|------|-------------|
| `AgentError` | Typed agent framework errors |
| `TransportError` | HTTP and network errors |

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
