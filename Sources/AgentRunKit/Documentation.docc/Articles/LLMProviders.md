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
| ``OpenAIClient`` | Bearer token (optional) | Yes | Yes (GPT-5/o-series) | No | Yes |
| ``AnthropicClient`` | x-api-key (required) | No | Yes (adaptive + manual) | Yes | No |
| ``GeminiClient`` | URL query param (required) | Yes | Yes (levels) | No | No |
| ``VertexAnthropicClient`` | OAuth closure (required) | No | Yes (adaptive + manual) | Yes | No |
| ``VertexGoogleClient`` | OAuth closure (required) | Yes | Yes | No | No |
| ``ResponsesAPIClient`` | Bearer token (optional) | Yes | Yes | No | No |

## Replay Fidelity

All providers deliver the same semantic fields on every assistant turn: content, tool calls, token usage, reasoning, and reasoning details. The agent loop operates on these fields and treats all providers identically.

Three clients preserve same-substrate continuity state, restoring provider-native turn structure from a continuity payload rather than reconstructing from semantic fields:

- ``ResponsesAPIClient``: preserves Responses API output items, including reasoning items and function call metadata.
- ``AnthropicClient``: preserves exact ordered assistant blocks (thinking, text, tool_use) in their original interleaved order.
- ``VertexAnthropicClient``: same Anthropic Messages substrate fidelity as ``AnthropicClient``.

Other clients (``OpenAIClient``, ``GeminiClient``) use semantic-only replay. History is reconstructed from the semantic fields, which is sufficient for the agent loop but does not preserve provider-specific turn metadata.

## ResponsesAPIClient vs OpenAIClient

Both connect to OpenAI. ``OpenAIClient`` uses the Chat Completions API, a stateless request/response protocol shared by many compatible providers (OpenRouter, Groq, Together, Ollama). ``ResponsesAPIClient`` uses the Responses API, which maintains server-side conversation state and supports delta requests that send only new messages since the last response.

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
    model: "gpt-5.4",
    baseURL: OpenAIClient.openAIBaseURL
)
```

### AnthropicClient

```swift
let client = AnthropicClient(
    apiKey: "sk-ant-...",
    model: "claude-sonnet-4-6",
    maxTokens: 4096
)
```

### GeminiClient

```swift
let client = GeminiClient(
    apiKey: "AIza...",
    model: "gemini-3.1-pro-preview"
)
```

### VertexAnthropicClient

```swift
let client = VertexAnthropicClient(
    projectID: "my-project",
    location: "us-east5",
    model: "claude-sonnet-4-6",
    tokenProvider: { try await fetchOAuthToken() }
)
```

### VertexGoogleClient

```swift
let client = VertexGoogleClient(
    projectID: "my-project",
    location: "us-central1",
    model: "gemini-3.1-pro-preview",
    tokenProvider: { try await fetchOAuthToken() }
)
```

### ResponsesAPIClient

```swift
let client = ResponsesAPIClient(
    apiKey: "sk-...",
    model: "gpt-5.4",
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

``ReasoningConfig`` is the shared reasoning-intent type. Anthropic's adaptive versus manual lowering is provider-local and
is selected with ``AnthropicReasoningOptions`` on ``AnthropicClient`` and ``VertexAnthropicClient``.

For Claude Opus 4.6 and Claude Sonnet 4.6, Anthropic's current recommended path is adaptive thinking:

```swift
let client = AnthropicClient(
    apiKey: "sk-ant-...",
    model: "claude-sonnet-4-6",
    maxTokens: 16384,
    reasoningConfig: .high,
    anthropicReasoning: .adaptive
)
```

The manual `budget_tokens` path is still supported and remains the right choice for older Anthropic models or for explicit
thinking-token budgets:

```swift
let client = AnthropicClient(
    apiKey: "sk-ant-...",
    model: "claude-opus-4-5-20251101",
    maxTokens: 16384,
    reasoningConfig: .budget(10000)
)
```

`interleavedThinking` is an Anthropic manual-mode control. Adaptive thinking enables interleaved thinking automatically when
the target model supports it.

OpenAI reasoning-capable models such as GPT-5.4 and o-series models, plus Gemini, use effort levels:

```swift
let client = OpenAIClient(
    apiKey: "sk-...",
    model: "gpt-5.4",
    baseURL: OpenAIClient.openAIBaseURL,
    reasoningConfig: .high
)
```

## See Also

- <doc:GettingStarted>
- <doc:StructuredOutput>
- <doc:AgentAndChat>
