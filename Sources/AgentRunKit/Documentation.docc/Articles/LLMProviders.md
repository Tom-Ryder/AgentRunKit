# LLM Providers

Choosing and configuring LLM provider clients.

## Overview

AgentRunKit connects to LLM providers through the ``LLMClient`` protocol. Six built-in clients cover OpenAI, Anthropic, Google Gemini, Vertex AI, and the OpenAI Responses API. All support both streaming and non-streaming generation.

## The LLMClient Protocol

``LLMClient`` defines two required methods and one optional property:

- `generate(messages:tools:responseFormat:requestContext:)` sends a request and returns a complete ``AssistantMessage``.
- `stream(messages:tools:requestContext:)` returns an `AsyncThrowingStream<StreamDelta, Error>` of incremental deltas.
- `contextWindowSize` optionally reports the model's token limit, used by context budgets and compaction.

Any type conforming to ``LLMClient`` works with ``Agent``, ``Chat``, and ``SubAgentTool``.

## Provider Feature Matrix

| Provider | Auth | Structured Output | Reasoning | Prompt Caching | Transcription |
|---|---|---|---|---|---|
| ``OpenAIClient`` | Bearer token (optional) | Yes | Yes (o1/o3) | No | Yes |
| ``AnthropicClient`` | x-api-key (required) | No | Yes (budget) | Yes | No |
| ``GeminiClient`` | URL query param (required) | Yes | Yes (levels) | No | No |
| ``VertexAnthropicClient`` | OAuth closure (required) | No | Yes | Yes | No |
| ``VertexGoogleClient`` | OAuth closure (required) | Yes | Yes | No | No |
| ``ResponsesAPIClient`` | Bearer token (optional) | Yes | Yes | No | No |

## OpenAI-Compatible Base URLs

``OpenAIClient`` works with any OpenAI-compatible API by changing the base URL. Static constants are provided for common providers:

| Constant | URL |
|---|---|
| `OpenAIClient.openAIBaseURL` | `https://api.openai.com/v1` |
| `OpenAIClient.openRouterBaseURL` | `https://openrouter.ai/api/v1` |
| `OpenAIClient.groqBaseURL` | `https://api.groq.com/openai/v1` |
| `OpenAIClient.togetherBaseURL` | `https://api.together.xyz/v1` |
| `OpenAIClient.ollamaBaseURL` | `http://localhost:11434/v1` |

For custom endpoints, use `OpenAIClient.proxy(baseURL:)`.

## Provider Examples

### OpenAIClient

```swift
let client = OpenAIClient(
    apiKey: "sk-...",
    model: "gpt-4o",
    baseURL: OpenAIClient.openAIBaseURL
)
```

### AnthropicClient

```swift
let client = AnthropicClient(
    apiKey: "sk-ant-...",
    model: "claude-sonnet-4-20250514",
    maxTokens: 4096
)
```

### GeminiClient

```swift
let client = GeminiClient(
    apiKey: "AIza...",
    model: "gemini-2.5-pro"
)
```

### VertexAnthropicClient

```swift
let client = VertexAnthropicClient(
    projectID: "my-project",
    location: "us-east5",
    model: "claude-sonnet-4@20250514",
    tokenProvider: { try await fetchOAuthToken() }
)
```

### VertexGoogleClient

```swift
let client = VertexGoogleClient(
    projectID: "my-project",
    location: "us-central1",
    model: "gemini-2.5-pro",
    tokenProvider: { try await fetchOAuthToken() }
)
```

### ResponsesAPIClient

```swift
let client = ResponsesAPIClient(
    apiKey: "sk-...",
    model: "gpt-4o",
    baseURL: ResponsesAPIClient.openAIBaseURL
)
```

## RetryPolicy

All clients accept a ``RetryPolicy`` controlling retry behavior on transient failures (HTTP 408, 429, 500, 502, 503, 504).

| Property | Default | Description |
|---|---|---|
| `maxAttempts` | 3 | Total attempts before failing |
| `baseDelay` | 1 second | Initial backoff duration |
| `maxDelay` | 30 seconds | Cap on exponential backoff |
| `streamStallTimeout` | nil | Restarts a stream if no delta arrives within this duration |

Two static presets: `.default` (3 attempts, 1s base, 30s max) and `.none` (single attempt, no retries).

```swift
let client = OpenAIClient(
    apiKey: "sk-...",
    baseURL: OpenAIClient.openAIBaseURL,
    retryPolicy: RetryPolicy(maxAttempts: 5, streamStallTimeout: .seconds(15))
)
```

## RequestContext

``RequestContext`` carries per-request metadata through the ``LLMClient`` call.

- `extraFields`: a `[String: JSONValue]` dictionary merged into the request body as top-level keys. Use this for provider-specific parameters not modeled in the client.
- `onResponse`: a callback receiving the raw `HTTPURLResponse`, useful for reading rate-limit headers or cache status.

```swift
let ctx = RequestContext(
    extraFields: ["user": .string("user-123")],
    onResponse: { response in
        print(response.allHeaderFields["x-ratelimit-remaining"] ?? "")
    }
)
try await agent.run(userMessage: "Hello", context: EmptyContext(), requestContext: ctx)
```

## ReasoningConfig

``ReasoningConfig`` controls extended thinking for models that support it. Pass it at client initialization.

Six effort-level presets map to provider-specific reasoning controls:

`.xhigh`, `.high`, `.medium`, `.low`, `.minimal`, `.none`

For Anthropic's token-budget style, use the `.budget(_:)` factory:

```swift
let client = AnthropicClient(
    apiKey: "sk-ant-...",
    model: "claude-sonnet-4-20250514",
    maxTokens: 16384,
    reasoningConfig: .budget(10000)
)
```

OpenAI reasoning models (o1, o3) and Gemini use effort levels:

```swift
let client = OpenAIClient(
    apiKey: "sk-...",
    model: "o3",
    baseURL: OpenAIClient.openAIBaseURL,
    reasoningConfig: .high
)
```

## See Also

- <doc:GettingStarted>
- <doc:StructuredOutput>
- <doc:AgentAndChat>
