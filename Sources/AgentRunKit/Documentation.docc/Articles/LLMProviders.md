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

| Provider | Auth | Structured Output | Reasoning | Multimodal | Prompt Caching | Transcription |
|---|---|---|---|---|---|---|
| ``OpenAIClient`` | Bearer token (optional) | Yes | Yes (GPT-5/o-series) | Images (URL, base64) | No | Yes |
| ``AnthropicClient`` | x-api-key (required) | Yes (`output_config.format`) | Yes (adaptive + manual) | Images, PDF (base64) | Yes | No |
| ``GeminiClient`` | URL query param (required) | Yes | Yes (budget or level) | Images, audio, video, PDF (`inlineData`) | No | No |
| ``VertexAnthropicClient`` | OAuth closure (required) | Yes (`output_config.format`) | Yes (adaptive + manual) | Images, PDF (base64) | Yes | No |
| ``VertexGoogleClient`` | OAuth closure (required) | Yes | Yes | Images, audio, video, PDF (`inlineData`) | No | No |
| ``ResponsesAPIClient`` | Bearer token (optional) | Yes | Yes | Images (URL, base64) | No | No |

Tool-calling capabilities vary by provider and profile. AgentRunKit resolves them per provider at request-build time and throws when the requested wire surface is unsupported instead of silently dropping fields.

## Replay Fidelity

All providers deliver the same semantic fields on every assistant turn: content, tool calls, token usage, reasoning, and reasoning details. The agent loop operates on these fields and treats all providers identically.

Three clients preserve same-substrate continuity state, restoring provider-native turn structure from a continuity payload rather than reconstructing from semantic fields:

- ``ResponsesAPIClient``: preserves Responses API output items, including reasoning items and function call metadata, and when `store == true` persists safe `response_id` anchors for restart-time same-substrate continuation.
- ``AnthropicClient``: preserves exact ordered assistant blocks in their original interleaved order, including forward-compatible opaque blocks.
- ``VertexAnthropicClient``: same Anthropic Messages substrate fidelity as ``AnthropicClient``.

Other clients (``OpenAIClient``, ``GeminiClient``) use semantic-only replay. History is reconstructed from the semantic fields, which is sufficient for the agent loop but does not preserve provider-specific turn metadata.

### Assistant Reasoning Replay on Chat Completions

``OpenAIClient`` parses reasoning fields (`reasoning`, `reasoning_content`, `reasoning_details`) from all provider responses. However, replaying those fields back onto later assistant turns is not universally safe across the diverse Chat Completions ecosystem.

Outbound replay is controlled by ``OpenAIChatAssistantReplayProfile``, which defaults to `.conservative` (omit all assistant-local reasoning fields from requests). This is the correct default because first-party OpenAI routes reasoning continuity through the Responses API, and other providers have heterogeneous replay contracts.

One opt-in profile is available:

- `.openRouterReasoningDetails`: emits `reasoning_details` on assistant turns, matching OpenRouter's documented Chat Completions replay contract. Does not emit `reasoning_content`.

```swift
let client = OpenAIClient.openRouter(
    apiKey: "sk-or-...",
    model: "anthropic/claude-sonnet-4.6",
    reasoningConfig: .high
)
```

`OpenAIClient.openRouter(...)` pins ``OpenAIChatProfile/openRouter`` and defaults ``OpenAIChatAssistantReplayProfile`` to `.openRouterReasoningDetails`.

Together's preserved-thinking replay depends on a provider-specific mode (`clear_thinking`) not yet modeled by the client, so it remains conservative in this release. For first-party OpenAI reasoning continuity, and for Responses-native OpenRouter models such as xAI Grok, use ``ResponsesAPIClient`` instead. See `Targeting OpenRouter with ResponsesAPIClient` below.

## ResponsesAPIClient vs OpenAIClient

``OpenAIClient`` uses the Chat Completions API, a stateless request/response protocol shared by many compatible providers (OpenRouter, Groq, Together, Ollama). ``ResponsesAPIClient`` uses the Responses API, a different wire format that carries richer turn state including reasoning items and provider-native output items. Against first-party OpenAI with `store == true`, it supports delta requests that send only new messages since a safe prior Responses turn, recovering `previous_response_id` either from the current client instance or from persisted `.responses` continuity in history. When local history rewrites break that continuation truth, the client drops only the continuation anchor and falls back to a full request or an earlier safe anchor.

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

xAI Grok models are the canonical case. Grok returns encrypted reasoning artifacts as Responses output items, and ``ResponsesAPIClient`` preserves those items in ``AssistantContinuity`` for lossless replay on the next turn. ``OpenAIClient`` with `.openRouterReasoningDetails` flattens reasoning back to Chat Completions `reasoning_details`, which is the right contract for Chat-Completions-native OpenRouter models but not for Responses-native Grok. Set `store: false` on ``ResponsesAPIClient`` when targeting OpenRouter: this makes the client request `reasoning.encrypted_content` and send full history on every call, and it disables `previous_response_id` continuation, which matches OpenRouter's stateless Responses routing.

``OpenAIClient`` remains the correct Chat Completions transport for OpenRouter models that are not Responses-native. The two clients are independent paths, not substitutes: pick the one the target model speaks.

## OpenAIChatProfile

``OpenAIClient`` talks to multiple Chat Completions backends. The wire surface differs (custom tools, strict function schemas, `max_completion_tokens` vs `max_tokens`), so the backend must be declared explicitly. ``OpenAIChatProfile`` has three cases:

| Profile | Target | Custom Tools | Strict Schemas | Token Field |
|---|---|---|---|---|
| `.firstParty` | `api.openai.com` | Yes | Yes | `max_completion_tokens` |
| `.openRouter` | `openrouter.ai` | No (rejected at request build) | No | `max_tokens` |
| `.compatible` | Groq, Together, Ollama, any OpenAI-compatible proxy | No | No | `max_tokens` |

Three factories pin the profile. Prefer them over the raw initializer:

```swift
let openai     = OpenAIClient.openAI(apiKey: "sk-...", model: "gpt-5.4")
let openRouter = OpenAIClient.openRouter(apiKey: "sk-or-...", model: "x-ai/grok-4")
let groq       = OpenAIClient.proxy(baseURL: OpenAIClient.groqBaseURL)
```

The designated initializer `OpenAIClient(...)` still accepts `profile:` directly and defaults to `.compatible`. Static base-URL constants remain available for proxy targets:

| Constant | URL |
|---|---|
| `OpenAIClient.openAIBaseURL` | `https://api.openai.com/v1` |
| `OpenAIClient.openRouterBaseURL` | `https://openrouter.ai/api/v1` |
| `OpenAIClient.groqBaseURL` | `https://api.groq.com/openai/v1` |
| `OpenAIClient.togetherBaseURL` | `https://api.together.xyz/v1` |
| `OpenAIClient.ollamaBaseURL` | `http://localhost:11434/v1` |

When a feature requires a specific profile (custom tools, strict function schemas, allowed-tools), the client throws ``TransportError/featureUnsupported(provider:feature:)`` rather than silently dropping the field on the wire.

## Provider Examples

### OpenAIClient

```swift
let client = OpenAIClient.openAI(apiKey: "sk-...", model: "gpt-5.4")
```

### AnthropicClient

``AnthropicClient`` validates its reasoning configuration against the target model at construction time, so the initializer is throwing:

```swift
let client = try AnthropicClient(
    apiKey: "sk-ant-...",
    model: "claude-sonnet-4-6",
    maxTokens: 4096
)
```

If the model demands a reasoning mode the configured options cannot satisfy (for example Claude Opus 4.7 with manual thinking, which the provider rejects server-side), the initializer throws ``TransportError/capabilityMismatch(model:requirement:)``.

### GeminiClient

```swift
let client = GeminiClient(
    apiKey: "AIza...",
    model: "gemini-3.1-pro-preview"
)
```

### VertexAnthropicClient

``VertexAnthropicClient`` inherits Anthropic's construction-time reasoning validation, so the initializer is throwing:

```swift
let client = try VertexAnthropicClient(
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

## Capability Resolvers and Forward Compatibility

Each Cloud provider ships a capability resolver that inspects the target model string and returns a typed, per-model view of the wire surface:

- ``OpenAIChatCapabilities/resolve(profile:)`` (indexed by ``OpenAIChatProfile``)
- ``AnthropicCapabilities/resolve(model:transport:)`` (indexed by ``AnthropicModelFamily``)
- ``GeminiCapabilities/resolve(model:)`` (indexed by ``GeminiModelFamily``)

Clients consult the resolver when building requests and throw ``TransportError/capabilityMismatch(model:requirement:)`` or ``TransportError/featureUnsupported(provider:feature:)`` rather than silently coerce an invalid wire.

Provider response items whose `type` the client does not recognize are preserved in provider-native continuity state as ``OpaqueResponseItem`` values and replayed verbatim on same-substrate continuation turns when replay is lossless. Anthropic continuity preserves ordered assistant blocks the same way and falls back to semantic replay when a streamed unknown block cannot be reconstructed safely. Malformed known payloads still throw.

## GoogleAuthService on iOS

``GoogleAuthService`` loads Application Default Credentials from `~/.config/gcloud` and is annotated `@available(iOS, unavailable)`. Vertex clients on iOS must be constructed with a caller-supplied `tokenProvider:` closure that returns a fresh OAuth access token; the `authService:` convenience initializer is macOS-only.

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
    retryPolicy: RetryPolicy(maxAttempts: 5, streamStallTimeout: .seconds(15)),
    profile: .firstParty
)
```

## RequestContext

``RequestContext`` carries per-request metadata through the ``LLMClient`` call.

- `extraFields`: a `[String: JSONValue]` dictionary merged into the request body as top-level keys. Use this for provider-specific parameters not modeled in the client.
- `onResponse`: a callback receiving the raw `HTTPURLResponse`, useful for reading rate-limit headers or cache status.
- `openAIChat`: typed OpenAI Chat request options such as custom tools, richer `tool_choice`, and `parallel_tool_calls`.
- `anthropic`: typed Anthropic request options such as ``AnthropicToolChoice``.
- `gemini`: typed Gemini request options such as ``GeminiFunctionCallingMode`` and `allowedFunctionNames`.
- `responses`: typed Responses request options such as hosted `file_search` and `web_search` tools.

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

Claude Opus 4.7 requires adaptive thinking; the manual `budget_tokens` path is rejected by the provider and the client throws ``TransportError/capabilityMismatch(model:requirement:)`` at construction time.

Anthropic's current adaptive-thinking models are Claude Opus 4.7, Claude Opus 4.6, and Claude Sonnet 4.6:

```swift
let client = try AnthropicClient(
    apiKey: "sk-ant-...",
    model: "claude-sonnet-4-6",
    maxTokens: 16384,
    reasoningConfig: .high,
    anthropicReasoning: .adaptive
)
```

The manual `budget_tokens` path remains the right choice for Claude Haiku 4.5 and older Anthropic 4.x models, or when you need an explicit thinking-token budget:

```swift
let client = try AnthropicClient(
    apiKey: "sk-ant-...",
    model: "claude-haiku-4-5",
    maxTokens: 16384,
    reasoningConfig: .budget(10000)
)
```

`interleavedThinking` is an Anthropic manual-mode control. Adaptive thinking enables interleaved thinking automatically when
the target model supports it.

OpenAI reasoning-capable models such as GPT-5.4 and o-series models, plus Gemini, use effort levels:

```swift
let client = OpenAIClient.openAI(
    apiKey: "sk-...",
    model: "gpt-5.4",
    reasoningConfig: .high
)
```

Gemini routes the effort level through `thinkingConfig`. The shape depends on the model family: Gemini 2.5 accepts an integer `thinkingBudget`, while Gemini 3 and later use a symbolic `thinkingLevel`. ``GeminiCapabilities/resolve(model:)`` picks the right shape automatically.

## See Also

- <doc:GettingStarted>
- <doc:StructuredOutput>
- <doc:AgentAndChat>
