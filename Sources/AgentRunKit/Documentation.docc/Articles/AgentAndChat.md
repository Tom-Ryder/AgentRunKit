# Agent and Chat

Two entry points for LLM interactions: ``Agent`` for tool-calling workflows, ``Chat`` for conversations and structured output.

## Overview

AgentRunKit provides ``Agent`` and ``Chat`` as its primary interfaces. Both support multi-turn history, streaming, and tool execution. They differ in loop semantics: ``Agent`` runs autonomously until a completion tool is called, while ``Chat`` returns after each LLM response (or after tool calls resolve).

## Agent

``Agent`` implements the full agent loop. It sends messages to the LLM, executes any tool calls, and repeats until the model calls the built-in `finish` tool. It supports compaction, token budgets, and context budget features. To finish through a tool of your own instead, see <doc:AgentAndChat#Custom-Completion-Tools>.

```swift
let agent = Agent(client: client, tools: [searchTool, calcTool], configuration: config)
let result = try await agent.run(
    userMessage: "Find the population of Tokyo and convert it to hex.",
    context: EmptyContext()
)
if let content = result.content {
    print(content)
}
```

``Agent`` also exposes `stream()`, which returns an `AsyncThrowingStream<StreamEvent, Error>` for real-time token delivery and tool progress. See <doc:StreamingAndSwiftUI>.

For long-running sessions, `stream()` accepts `sessionID:` and `checkpointer:` parameters that persist iteration state to a backend implementing ``AgentCheckpointer``. ``Agent/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` reconstructs a stopped run from any saved ``CheckpointID``. See <doc:CheckpointAndResume>.

Key behaviors:
- Injects a `finish` tool automatically unless a `completionTool:` is supplied. The model must call one of the two to end the loop.
- Alternate termination for on-device clients: when the LLM client cannot surface tool calls in its response (e.g., `FoundationModelsClient`), the loop terminates on the first iteration that produces content without tool calls. The user-visible contract is unchanged. This applies only to built-in `finish` agents; see <doc:AgentAndChat#Custom-Completion-Tools>.
- Enforces ``AgentConfiguration/maxIterations`` to prevent runaway loops (default: 10).
- Supports context compaction via ``AgentConfiguration/compactionThreshold`` and ``AgentConfiguration/compactionPrompt``.
- Accepts a `tokenBudget` parameter on each `run()` or `stream()` call.
- Returns structural terminal reasons for expected runtime limits. `run()` returns ``AgentResult`` with `.maxIterationsReached(limit:)` or `.tokenBudgetExceeded(budget:used:)`, and `stream()` emits `.finished(..., reason: ...)` for the same states instead of throwing.
- Cancellation remains cancellation. `run()` still propagates `CancellationError`, and cancelling a consumer of `stream()` does not guarantee a terminal `.finished` event.

## Custom Completion Tools

``Agent`` has two initializers with different termination contracts. ``Agent/init(client:tools:configuration:)`` advertises the built-in `finish` tool and accepts any ``LLMClient``. ``Agent/init(client:tools:completionTool:configuration:)`` designates one of your own typed tools as the terminal operation, and takes a ``ToolCallSurfacingClient``: a client that returns structured calls for the definitions it is given rather than executing them itself. Every HTTP provider client and `MLXClient` conform. `FoundationModelsClient` does not, because it runs tools inside its own session and never surfaces the calls the loop would have to execute, so custom completion is unavailable on that backend.

```swift
let publishTool = try Tool<PublishParams, String, ReportContext>(
    name: "publish_report",
    description: """
    Publish the finished report and end the task. \
    Call this tool alone; it must be the only tool call in its message.
    """
) { params, context in
    try await context.store.publish(params)
}

let agent = Agent(
    client: client,
    tools: [searchTool, draftTool],
    completionTool: publishTool
)
```

A factory that hides the provider choice keeps the refinement in its own type so custom construction still compiles:

```swift
typealias LLMClientFactory = @Sendable () throws -> any ToolCallSurfacingClient
```

The completion tool joins the ordinary tools in one namespace. Duplicate names, a collision between an ordinary tool and the completion tool, an empty name, and the reserved names `finish` and `prune_context` are all initializer precondition failures. Selecting a completion tool withdraws the synthetic `finish` definition entirely: the model sees your tools plus `prune_context` when enabled, and nothing else.

### Exclusivity

The completion tool must be the only call in its assistant message. State that in its description, as the example above does — the framework never rewrites your description or schema.

When the model calls it anyway alongside other tools, or calls it twice, the loop executes nothing from that message. No prune runs, no approval is requested, no ordinary, MCP, or sub-agent call is dispatched. Each call in the batch receives an error tool result explaining that the completion tool must be called alone and that nothing was executed, and the run continues so the model can correct itself on the next turn. Violations consume iterations like any other turn, so ``AgentConfiguration/maxIterations`` bounds a model that keeps repeating the mistake.

Where a provider offers a native single-call control, using it prevents the situation rather than correcting it:

| Provider | Control |
|---|---|
| ``OpenAIClient`` | `parallelToolCalls` on ``OpenAIChatRequestOptions`` |
| ``ResponsesAPIClient`` | `parallel_tool_calls` through ``RequestContext`` `extraFields` |
| ``AnthropicClient``, ``VertexAnthropicClient`` | `disableParallel` on ``AnthropicToolChoice`` |

``GeminiClient``, ``VertexGoogleClient``, and `MLXClient` have no equivalent; agents on those backends rely on the tool description and the feedback loop. Forced tool choice, where a provider offers it, can push a reluctant model to the finalizer, but forcing a tool call needs its own exit condition or the model can never do ordinary work.

### Execution and results

The completion tool executes through the same path as any other tool: typed argument decoding, your tool context, approval policy and handler, per-tool timeout, and MCP or sub-agent dispatch. Only an exact success terminates the run.

- **Success.** The result is used verbatim. Per-tool and global result truncation do not apply, the exact text becomes the last tool message and the run's `content`, and the loop returns ``FinishReason/completed``.
- **Failure.** A denied approval, a timeout, a thrown error, a decode failure, or a result the tool marked as an error is truncated and appended like any other error result, and the model may try again on a later turn. Cancellation still propagates instead of becoming feedback.

Because failures and exclusivity violations are both retried by the model, a completion tool that performs side effects may run more than once in a single agent run. Write finalizers to be idempotent.

Content-only termination is disabled for custom completion agents. A client that would normally end an agent run on prose alone cannot bypass your finalizer; such a run continues until the tool succeeds or a structural limit stops it.

## Chat

``Chat`` handles multi-turn conversations without requiring a finish tool. Each `send()` call makes one LLM request and returns the response with updated history. Tool calls in the response are not automatically executed; use `stream()` for tool execution.

When the model does call tools in a `send()` response, the returned history ends with an unexecuted tool-call batch. Passing that history straight back to `send()` throws `AgentError.malformedHistory` with reason `.unfinishedToolCallBatch`: execute the calls yourself and append a `.tool` message for each call id before the next turn, or use `stream()`, which runs the tool loop for you.

```swift
let chat = Chat<EmptyContext>(client: client, systemPrompt: "You are a helpful assistant.")
let (response, history) = try await chat.send("What is 2 + 2?")
let (followUp, _) = try await chat.send("Now multiply that by 10.", history: history)
```

For structured output, use the `returning:` overload with any `Decodable & SchemaProviding` type:

```swift
struct Sentiment: Codable, SchemaProviding { let score: Double; let label: String }
let (result, _) = try await chat.send("Analyze: 'Great product!'", returning: Sentiment.self)
print(result.score) // 0.95
```

Structured sends suppress tools for that turn: the request carries an empty tool list so the model produces the JSON payload instead of tool calls.

``Chat`` also supports streaming via `stream()` and tool execution (up to `maxToolRounds` per send). When `stream()` exhausts `maxToolRounds`, it emits `.finished(reason: .maxIterationsReached(limit: maxToolRounds))` and completes normally. ``Chat`` does not perform compaction or manage token budgets.

## Choosing an Entry Point

| Entry Point | Use When |
|---|---|
| ``Agent`` | The model needs to call tools autonomously across multiple iterations |
| ``Chat`` | You want multi-turn conversation, structured output, or simple tool use |
| `client.stream()` | You need raw SSE deltas without any agent loop or tool execution |
| `client.generate()` | You need a single request/response with no loop |

## AgentConfiguration

``AgentConfiguration`` controls ``Agent`` behavior. All properties have sensible defaults.

**Iteration and timeouts:**

| Property | Default | Description |
|---|---|---|
| `maxIterations` | 10 | Maximum generate/tool-call cycles before returning `.maxIterationsReached(limit:)` |
| `toolTimeout` | 30s | Default per-tool execution timeout. Individual tools override it; see <doc:DefiningTools#Per-Tool-Timeout>. |

**System prompt:**

| Property | Default | Description |
|---|---|---|
| `systemPrompt` | nil | Prepended as a system message to every request |

**Context management:**

| Property | Default | Description |
|---|---|---|
| `maxMessages` | nil | Sliding window: keeps the N most recent messages (system prompt preserved) |
| `compactionThreshold` | nil | Token usage ratio (0, 1) that triggers LLM-based summarization |
| `compactionPrompt` | nil | Custom prompt for the summarization request |
| `maxToolResultCharacters` | nil | Default limit for tool result truncation; individual tools can override via ``AnyTool/maxResultCharacters`` |

**Context budget:**

| Property | Default | Description |
|---|---|---|
| `contextBudget` | nil | ``ContextBudgetConfig`` enabling visibility injection, soft-threshold advisories, and the `prune_context` tool |

See <doc:ContextManagement> for details on compaction and context budgets.

## AgentResult

``AgentResult`` is returned by `run(userMessage:history:context:tokenBudget:requestContext:)` on ``Agent``.

| Field | Type | Description |
|---|---|---|
| `content` | `String?` | The text passed to the finish tool or returned by the completion tool, or `nil` when the loop ends structurally without one |
| `finishReason` | ``FinishReason`` | `.completed`, `.error`, `.maxIterationsReached(limit:)`, `.tokenBudgetExceeded(budget:used:)`, or `.custom(_:)` |
| `totalTokenUsage` | ``TokenUsage`` | Accumulated input/output tokens across all iterations |
| `iterations` | `Int` | Number of generate/tool-call cycles executed |
| `history` | `[ChatMessage]` | Full conversation including system prompt, user messages, assistant responses, and tool results |

Completed paths — the `finish` tool, a successful completion tool, or a content-only iteration from an on-device client — produce non-`nil` content. Structural runtime termination does not synthesize an empty string.

A `finish` call is sanitized out of the returned history, because it is framework protocol rather than conversation. A successful completion tool call is not: it really executed, so its assistant call and tool result stay in the history exactly as they ran.

## Multi-Turn History

Both ``Agent`` and ``Chat`` accept a `history` parameter. Pass the history from a previous result to continue the conversation:

```swift
let first = try await agent.run(userMessage: "Search for Swift concurrency.", context: ctx)
let second = try await agent.run(
    userMessage: "Summarize what you found.",
    history: first.history,
    context: ctx
)
```

The same pattern works with ``Chat``:

```swift
let (_, history) = try await chat.send("Hello")
let (_, history2) = try await chat.send("Tell me more.", history: history)
```

## See Also

- <doc:GettingStarted>
- <doc:DefiningTools>
- <doc:StreamingAndSwiftUI>
- <doc:ContextManagement>
- <doc:CheckpointAndResume>
