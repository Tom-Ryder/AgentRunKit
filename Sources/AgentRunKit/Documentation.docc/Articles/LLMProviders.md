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

### Assistant Reasoning Replay on Chat Completions

``OpenAIClient`` parses reasoning fields (`reasoning`, `reasoning_content`, `reasoning_details`) from all provider responses. However, replaying those fields back onto later assistant turns is not universally safe across the diverse Chat Completions ecosystem.

Outbound replay is controlled by ``OpenAIChatAssistantReplayProfile``, which defaults to `.conservative` (omit all assistant-local reasoning fields from requests). This is the correct default because first-party OpenAI routes reasoning continuity through the Responses API, and other providers have heterogeneous replay contracts.

One opt-in profile is available:

- `.openRouterReasoningDetails`: emits `reasoning_details` on assistant turns, matching OpenRouter's documented Chat Completions replay contract. Does not emit `reasoning_content`.

```swift
let client = OpenAIClient(
    apiKey: "sk-or-...",
    model: "anthropic/claude-sonnet-4",
    baseURL: OpenAIClient.openRouterBaseURL,
    reasoningConfig: .high,
    assistantReplayProfile: .openRouterReasoningDetails
)
```

Together's preserved-thinking replay depends on a provider-specific mode (`clear_thinking`) not yet modeled by the client, so it remains conservative in this release. For first-party OpenAI reasoning continuity, and for Responses-native OpenRouter models such as xAI Grok, use ``ResponsesAPIClient`` instead. See `Targeting OpenRouter with ResponsesAPIClient` below.

## ResponsesAPIClient vs OpenAIClient

``OpenAIClient`` uses the Chat Completions API, a stateless request/response protocol shared by many compatible providers (OpenRouter, Groq, Together, Ollama). ``ResponsesAPIClient`` uses the Responses API, a different wire format that carries richer turn state including reasoning items and provider-native output items. Against first-party OpenAI, it also maintains server-side conversation state and supports delta requests that send only new messages since the last response.

### Targeting OpenRouter with ResponsesAPIClient

``ResponsesAPIClient`` is not locked to OpenAI. It accepts any base URL and works with OpenRouter's `/v1/responses` endpoint for models that OpenRouter routes through the Responses protocol. Point it at `OpenAIClient.openRouterBaseURL`:

```swift
let client = ResponsesAPIClient(
    apiKey: "sk-or-...",
    model: "x-ai/grok-4",
    maxOutputTokens: 4096,
    baseURL: OpenAIClient.openRouterBaseURL,
    reasoningConfig: .high,
    store: false
)
```

Prefer ``ResponsesAPIClient`` over ``OpenAIClient`` on OpenRouter when:

- The target model is Responses-API-native rather than Chat-Completions-native.
- Provider-native reasoning continuity depends on preserving full Responses output items across turns.

xAI Grok models are the canonical case. Grok returns encrypted reasoning artifacts as Responses output items, and ``ResponsesAPIClient`` preserves those items in ``AssistantContinuity`` for lossless replay on the next turn. ``OpenAIClient`` with `.openRouterReasoningDetails` flattens reasoning back to Chat Completions `reasoning_details`, which is the right contract for Chat-Completions-native OpenRouter models but not for Responses-native Grok. Set `store: false` on ``ResponsesAPIClient`` when targeting OpenRouter: this makes the client request `reasoning.encrypted_content` and send full history on every call, which matches OpenRouter's stateless Responses routing.

``OpenAIClient`` remains the correct Chat Completions transport for OpenRouter models that are not Responses-native. The two clients are independent paths, not substitutes: pick the one the target model speaks.

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
