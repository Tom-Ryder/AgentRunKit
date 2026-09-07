# LLM Providers

Choosing and configuring LLM provider clients.

## Overview

AgentRunKit connects to LLM providers through the ``LLMClient`` protocol. Eight built-in clients cover OpenAI, Anthropic, Google Gemini, Vertex AI, the OpenAI Responses API, and on-device inference through Foundation Models and MLX. All support both streaming and non-streaming generation.

## The LLMClient Protocol

``LLMClient`` defines two required methods and one optional property:

- `generate(messages:tools:responseFormat:requestContext:)` sends a request and returns a complete ``AssistantMessage``.
- `stream(messages:tools:requestContext:)` returns an `AsyncThrowingStream<StreamDelta, Error>` of incremental deltas.
- `contextWindowSize` optionally reports the model's token limit, used by context budgets and compaction.

Any type conforming to ``LLMClient`` works with ``Agent``, ``Chat``, and ``SubAgentTool``.

``ToolCallSurfacingClient`` refines it with one promise: the client returns structured calls for the definitions it is given and never executes them itself. That is what lets the loop own a caller's completion tool, so ``Agent/init(client:tools:completionTool:configuration:)`` requires the refinement. Every client in the matrix below conforms except `FoundationModelsClient`, which executes tools inside Apple's session. Conform your own client to it when it surfaces calls the same way; the requirement is behavioral, and the compiler cannot check it for you.

## Provider Feature Matrix

| Provider | Auth | Structured Output | Reasoning | Multimodal | Prompt Cache Controls | Transcription |
|---|---|---|---|---|---|---|
| ``OpenAIClient`` | Bearer token (optional) | Yes | Yes (GPT-5/o-series) | Images (URL, base64) | Provider-managed | Yes |
| ``AnthropicClient`` | x-api-key (required) | Yes (`output_config.format`) | Yes (adaptive + manual) | Images, PDF (base64) | Cache breakpoints | No |
| ``GeminiClient`` | URL query param (required) | Yes | Yes (budget or level) | Images, audio, video, PDF (`inlineData`) | `cachedContent` via `extraFields` | No |
| ``VertexAnthropicClient`` | OAuth closure (required) | Yes (`output_config.format`) | Yes (adaptive + manual) | Images, PDF (base64) | Cache breakpoints | No |
| ``VertexGoogleClient`` | OAuth closure (required) | Yes | Yes | Images, audio, video, PDF (`inlineData`) | `cachedContent` via `extraFields` | No |
| ``ResponsesAPIClient`` | Bearer token (optional) | Yes | Yes | Images (URL, base64) | Provider-managed | No |
| `FoundationModelsClient` | None | Schema-driven tools | Apple-managed | Text | None exposed | No |
| `MLXClient` | None | Model/template dependent | Model/template dependent | Text | None exposed | No |

Cache controls describe request configuration. An endpoint can reuse a prefix and report cached tokens without a framework cache option. Cache reuse depends on the provider, model, and routing; returned token measurements describe the response the endpoint reported.

Tool-calling capabilities vary by provider and profile. AgentRunKit resolves them per provider at request-build time and throws when the requested wire surface is unsupported instead of silently dropping fields.

## Replay Fidelity

All providers deliver the same semantic fields on every assistant turn: content, tool calls, token usage, reasoning, and reasoning details. The agent loop operates on these fields and treats all providers identically.

Three clients preserve same-substrate continuity state, restoring provider-native turn structure from a continuity payload rather than reconstructing from semantic fields:

- ``ResponsesAPIClient``: preserves Responses API output items, including reasoning items and function call metadata, and when `store == true` persists safe `response_id` anchors for restart-time same-substrate continuation.
- ``AnthropicClient``: preserves exact ordered assistant blocks in their original interleaved order, including forward-compatible opaque blocks.
- ``VertexAnthropicClient``: same Anthropic Messages substrate fidelity as ``AnthropicClient``.

Other clients (``OpenAIClient``, ``GeminiClient``) use semantic-only replay. History is reconstructed from the semantic fields, which is sufficient for the agent loop but does not preserve provider-specific turn metadata.

`FoundationModelsClient` runs on-device through Apple's Foundation Models framework and requires iOS 26+ or macOS 26+. Apple's session owns tool dispatch internally, so the AgentRunKit adapter maps the resulting content back into the shared agent loop.

`MLXClient` runs on-device through the `AgentRunKitMLX` target on Apple Silicon. Tool-call and structured-output fidelity depends on the selected local model and chat template.

### Assistant Reasoning Replay on Chat Completions

``OpenAIClient`` parses reasoning fields (`reasoning`, `reasoning_content`, `reasoning_details`) from all provider responses. However, replaying those fields back onto later assistant turns is not universally safe across the diverse Chat Completions ecosystem.

Outbound replay is controlled by ``OpenAIChatAssistantReplayProfile``, which defaults to `.conservative` (omit all assistant-local reasoning fields from requests). This is the correct default because first-party OpenAI routes reasoning continuity through the Responses API, and other providers have heterogeneous replay contracts.

Two opt-in profiles are available:

- `.openRouterReasoningDetails`: emits `reasoning_details` on assistant turns, matching OpenRouter's documented Chat Completions replay contract. Does not emit `reasoning_content`.
- `.reasoningContent`: emits `reasoning_content` on every prior assistant turn that includes tool calls. This matches Together's current reasoning models (GLM-5.2, MiniMax-M3, Kimi-K2.6) and DeepSeek's V4 thinking mode, which re-admit the trace through `reasoning_content`.

```swift
let client = OpenAIClient.openRouter(
    apiKey: "sk-or-...",
    model: "anthropic/claude-sonnet-4.6",
    reasoningConfig: .high
)
```

`OpenAIClient.openRouter(...)` pins ``OpenAIChatProfile/openRouter`` and defaults ``OpenAIChatAssistantReplayProfile`` to `.openRouterReasoningDetails`.

Reasoning replay is best-effort. Some models return no `reasoning_details` on a given turn (for example GPT-class models routed through Chat Completions, which expose replayable reasoning only through the Responses API). When that happens the assistant turn carries no replayable reasoning and `reasoning_details` is absent from the next request. A workflow that requires replayable reasoning continuity can detect this by inspecting the reasoning details on the returned assistant message, such as the last assistant entry in ``AgentResult/history``.

Together's current reasoning models emit chain-of-thought in the `reasoning` field and re-admit it across tool-call turns only through `reasoning_content`; echoing the emitted `reasoning` field back is ignored. ``OpenAIClient/together(apiKey:model:maxTokens:contextWindowSize:assistantReplayProfile:)`` reads `reasoning` inbound, replays `reasoning_content` on every prior tool-call turn, and sends `chat_template_kwargs={"clear_thinking": false, "thinking": true}` so the model emits its reasoning and retains it across tool-call turns (Together's Preserved Thinking mode, on by default for this client). It pins the compatible backend and identifies errors as `together`:

```swift
let client = OpenAIClient.together(
    apiKey: "sk-together-...",
    model: "zai-org/GLM-5.2"
)
```

Validated pairings are intentionally narrow: `.reasoningContent` is verified against Together's current reasoning models and is consistent with DeepSeek's V4 thinking mode. Pairing it with the OpenRouter backend, or replaying reasoning resumed from a non-OpenAI-chat checkpoint, is unsupported and may be ignored or rejected by the endpoint. The replay profile remains independently overridable so callers can target compatible endpoints not yet covered by a factory.

`.reasoningContent` replays every prior tool-call turn's trace, so pair ``OpenAIClient/together(apiKey:model:maxTokens:contextWindowSize:assistantReplayProfile:)`` with a `contextWindowSize` if prompt growth should trigger compaction. The `prune_context` tool prunes tool results only; surviving assistant reasoning is still replayed and can refer to pruned observations.

For first-party OpenAI reasoning continuity, and for Responses-native OpenRouter models such as xAI Grok, use ``ResponsesAPIClient`` instead. See `Targeting OpenRouter with ResponsesAPIClient` below.

## ResponsesAPIClient vs OpenAIClient

``OpenAIClient`` uses the Chat Completions API, a stateless request/response protocol shared by many compatible providers (OpenRouter, Groq, Together, Ollama). ``ResponsesAPIClient`` uses the Responses API, a different wire format that carries richer turn state including reasoning items and provider-native output items. Against first-party OpenAI with `store == true`, it supports delta requests that send only new messages since a safe prior Responses turn, recovering `previous_response_id` either from the current client instance or from persisted `.responses` continuity in history. When local history rewrites break that continuation truth, the client drops only the continuation anchor and falls back to a full request or an earlier safe anchor.

### Targeting OpenRouter with ResponsesAPIClient

``ResponsesAPIClient`` is not locked to OpenAI. It accepts any base URL and works with OpenRouter's `/v1/responses` endpoint for models that OpenRouter routes through the Responses protocol. The `ResponsesAPIClient.openRouter(...)` factory pins ``ResponsesAPIClient/openRouterBaseURL`` and `store: false`:

```swift
let client = ResponsesAPIClient.openRouter(
    apiKey: "sk-or-...",
    model: "x-ai/grok-4",
    maxOutputTokens: 4096,
    reasoningConfig: .high
)
```

Prefer ``ResponsesAPIClient`` over ``OpenAIClient`` on OpenRouter when:

- The target model is Responses-API-native rather than Chat-Completions-native.
- Provider-native reasoning continuity depends on preserving full Responses output items across turns.

xAI Grok models are the canonical case. Grok returns encrypted reasoning artifacts as Responses output items, and ``ResponsesAPIClient`` preserves those items in ``AssistantContinuity`` for lossless replay on the next turn. ``OpenAIClient`` with `.openRouterReasoningDetails` flattens reasoning back to Chat Completions `reasoning_details`, which is the right contract for Chat-Completions-native OpenRouter models but not for Responses-native Grok. The `openRouter(...)` factory sets `store: false`: this makes the client request `reasoning.encrypted_content` and send full history on every call, and it disables `previous_response_id` continuation, which matches OpenRouter's stateless Responses routing.

``OpenAIClient`` remains the correct Chat Completions transport for OpenRouter models that are not Responses-native. The two clients are independent paths, not substitutes: pick the one the target model speaks.

## OpenAIChatProfile

``OpenAIClient`` talks to multiple Chat Completions backends. The wire surface differs (custom tools, strict function schemas, `max_completion_tokens` vs `max_tokens`), so the backend must be declared explicitly. ``OpenAIChatProfile`` has three cases:

| Profile | Target | Custom Tools | Strict Schemas | Token Field |
|---|---|---|---|---|
| `.firstParty` | `api.openai.com` | Yes | Yes | `max_completion_tokens` |
| `.openRouter` | `openrouter.ai` | No (rejected at request build) | No | `max_tokens` |
| `.compatible` | Groq, Together, Ollama, any OpenAI-compatible proxy | No | No | `max_tokens` |

Four factory paths pin the profile. Prefer them over the raw initializer:

```swift
let openai     = OpenAIClient.openAI(apiKey: "sk-...", model: "gpt-5.4")
let openRouter = OpenAIClient.openRouter(apiKey: "sk-or-...", model: "x-ai/grok-4")
let together   = OpenAIClient.together(apiKey: "sk-together-...", model: "zai-org/GLM-5.2")
let groq       = OpenAIClient.proxy(baseURL: OpenAIClient.groqBaseURL)
```

The designated initializer `OpenAIClient(...)` accepts `profile:` directly and defaults to `.compatible`. Static base-URL constants are available for proxy targets:

| Constant | URL |
|---|---|
| `OpenAIClient.openAIBaseURL` | `https://api.openai.com/v1` |
| `OpenAIClient.openRouterBaseURL` | `https://openrouter.ai/api/v1` |
| `OpenAIClient.groqBaseURL` | `https://api.groq.com/openai/v1` |
| `OpenAIClient.togetherBaseURL` | `https://api.together.ai/v1` |
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
| `streamStallTimeout` | nil | Fails a stream with ``StreamFailure/idleTimeout(diagnostics:)`` when no bytes arrive within this duration |

Two static presets: `.default` (3 attempts, 1s base, 30s max) and `.none` (single attempt, no retries).

Retries apply before a stream starts; once a 2xx byte stream is open, failures propagate to the caller as typed ``StreamFailure`` values rather than being retried.

## Stream Termination

Each streaming transport defines exactly which wire conditions end a stream successfully; anything else throws a typed ``StreamFailure``.

- OpenAI-compatible Chat Completions: a `data: [DONE]` sentinel completes the stream immediately. A terminal non-`error` `finish_reason` also marks the turn complete, so a stream that ends at EOF after one is a successful completion (reported through ``StreamCompletionDiagnostics/terminalMarkerSeen``). Frames carrying a top-level `error` payload, or `finish_reason: "error"`, throw ``StreamFailure/providerError(code:message:diagnostics:)`` with the upstream code and message preserved. EOF with no finish signal throws ``StreamFailure/providerTerminationMissing(diagnostics:)``, and a `[DONE]` with no preceding finish signal throws ``StreamFailure/finishedDeltaMissing(diagnostics:)``.
- Anthropic (and Vertex Anthropic): `message_stop` completes the stream; `error` events throw ``StreamFailure/providerError(code:message:diagnostics:)``; EOF before `message_stop` throws ``StreamFailure/providerTerminationMissing(diagnostics:)``.
- Gemini (and Vertex Gemini): a chunk with `finishReason` completes the stream; error envelopes throw ``StreamFailure/providerError(code:message:diagnostics:)``.
- Responses API: `response.completed` and `response.incomplete` complete the stream; `response.failed`, `response.error`, and standalone `error` events throw ``StreamFailure/providerError(code:message:diagnostics:)``.

Every failure carries ``StreamFailureDiagnostics`` identifying the provider, elapsed time, events observed, and whether a finish signal had been seen before the failure.

```swift
let client = OpenAIClient(
    apiKey: "sk-...",
    baseURL: OpenAIClient.openAIBaseURL,
    retryPolicy: RetryPolicy(maxAttempts: 5, streamStallTimeout: .seconds(15)),
    profile: .firstParty
)
```

## Request Serialization

All six HTTP clients sort JSON object members when encoding request bodies, including nested tool schemas. A stable encoded structure has a deterministic object-member order on the supported Foundation runtime. Tool lists, messages, schema `required` and `enum` arrays, alternatives, and content blocks retain their supplied order.

HTTP serialization preserves string values, including JSON-looking tool arguments and opaque reasoning or signatures. It does not parse and rewrite authored strings. Schema properties remain unordered dictionaries; encoding a ``JSONSchema`` with your own `JSONEncoder` uses that encoder's settings.

This guarantee concerns HTTP request serialization, not universal JSON canonicalization or a downstream model's prompt renderer. Custom `Encodable` implementations must still produce stable values and ordered arrays, and Foundation's object-ordering behavior can differ across runtimes. Provider cache reuse remains dependent on the endpoint's caching and routing behavior.

## RequestContext

``RequestContext`` carries per-request metadata through the ``LLMClient`` call.

- `extraFields`: a `[String: JSONValue]` dictionary merged into the request body as top-level keys. Use this for provider-specific parameters not modeled in the client.
- `onResponse`: a callback receiving the raw `HTTPURLResponse`, useful for reading HTTP metadata such as rate-limit headers.
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

## Token Measurements

Token counts arrive in ``AssistantMessage/tokenUsage`` and ``StreamDelta/finished(usage:)``. The `onResponse` callback exposes HTTP metadata; it does not decode response-body usage.

Chat Completions and Responses normalize inclusive input, output, reasoning, and optional cache breakdowns at their wire boundary:

| Client | Inclusive input | Inclusive output | Reasoning breakdown | Cache breakdown |
|---|---|---|---|---|
| ``OpenAIClient`` | `prompt_tokens` | `completion_tokens` | `completion_tokens_details.reasoning_tokens` | `prompt_tokens_details.cached_tokens` and optional `cache_write_tokens` |
| ``ResponsesAPIClient`` | `input_tokens` | `output_tokens` | `output_tokens_details.reasoning_tokens` | `input_tokens_details.cached_tokens` and optional `cache_write_tokens` |

Separately reported reasoning is subtracted from inclusive output and stored in ``TokenUsage/reasoning``. Without that breakdown, output remains undifferentiated and reasoning is zero. Cache reads and writes are portions of input, so they are not added again to ``TokenUsage/total``. An absent/null cache field remains nil; an explicit zero remains zero.

Gemini and Vertex Google share the `usageMetadata` mapping for their `generateContent` endpoints. Input is `promptTokenCount` plus `toolUsePromptTokenCount`, which reports additional input from tool-use prompts. Cached content is already part of `promptTokenCount` and remains a breakdown of that count, so it is not added again. `candidatesTokenCount` and `thoughtsTokenCount` remain separate output and reasoning counts. Within a present metadata object, omitted/null prompt, tool-use prompt, candidate, thought, and cached-content counters all default to zero under the protocol's scalar-presence rules. An empty object therefore represents measured zeros, including `cacheRead: 0`; `cacheWrite` remains unavailable. If adding the two input counts overflows, usage is unavailable while the assistant response remains valid. The adapter does not derive counts from `totalTokenCount` or carry earlier stream metadata into the terminal snapshot. A wholly absent/null metadata object yields nil usage.

Anthropic and Vertex Anthropic share one normalization path. Their `input_tokens` excludes cached input, so the adapter adds `cache_read_input_tokens` and `cache_creation_input_tokens` once to produce inclusive input. Missing cache fields contribute no reported amount and remain nil in the breakdown. `output_tokens` includes thinking: when `output_tokens_details` is present, its required `thinking_tokens` count becomes reasoning and is subtracted from output. Without that object, output remains undifferentiated.

Anthropic stream usage is cumulative. Each reported delta field replaces the previous input, cache, or thinking value, including explicit zero; absent/null optional fields leave known values intact. The start message can seed these fields, but its provisional output count does not complete a measurement. Final usage requires known input and an output count from a delta. A later delta can supply input when start usage was missing. No delta usage report means final usage is nil; a present delta usage object must contain `output_tokens`.

For every HTTP adapter, malformed token fields throw ``TransportError/decodingFailed(description:)`` through ``AgentError/llmError(_:)``. Wrong types, negative counts, out-of-range integers, and missing required fields are malformed. Structurally valid counts whose relationships cannot normalize, such as reasoning exceeding inclusive output, a cache component exceeding inclusive input, or Anthropic's input sum overflowing, yield nil usage while preserving otherwise valid content, tool calls, and continuity. Responses still advances a valid continuation cursor in that case. Chat streaming retains the latest reported snapshot: an unusable report clears earlier usage, while a missing/null usage block leaves the prior snapshot intact.

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
