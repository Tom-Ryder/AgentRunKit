# Agent and Chat

Two entry points for LLM interactions: ``Agent`` for tool-calling workflows, ``Chat`` for conversations and structured output.

## Overview

AgentRunKit provides ``Agent`` and ``Chat`` as its primary interfaces. Both support multi-turn history, streaming, and tool execution. They differ in loop semantics: ``Agent`` runs autonomously until a finish tool is called, while ``Chat`` returns after each LLM response (or after tool calls resolve).

## Agent

``Agent`` implements the full agent loop. It sends messages to the LLM, executes any tool calls, and repeats until the model calls the built-in `finish` tool. It supports compaction, token budgets, and context budget features.

```swift
let agent = Agent(client: client, tools: [searchTool, calcTool], configuration: config)
let result = try await agent.run(
    userMessage: "Find the population of Tokyo and convert it to hex.",
    context: EmptyContext()
)
print(result.content) // "0xD59F2C0"
```

``Agent`` also exposes `stream()`, which returns an `AsyncThrowingStream<StreamEvent, Error>` for real-time token delivery and tool progress. See <doc:StreamingAndSwiftUI>.

Key behaviors:
- Injects a `finish` tool automatically. The model must call it to end the loop.
- Enforces ``AgentConfiguration/maxIterations`` to prevent runaway loops (default: 10).
- Supports context compaction via ``AgentConfiguration/compactionThreshold`` and ``AgentConfiguration/compactionPrompt``.
- Accepts a `tokenBudget` parameter on each `run()` or `stream()` call.

## Chat

``Chat`` handles multi-turn conversations without requiring a finish tool. Each `send()` call makes one LLM request and returns the response with updated history. Tool calls in the response are not automatically executed; use `stream()` for tool execution.

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

``Chat`` also supports streaming via `stream()` and tool execution (up to `maxToolRounds` per send). It does not perform compaction or manage token budgets.

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
| `maxIterations` | 10 | Maximum generate/tool-call cycles before throwing |
| `toolTimeout` | 30s | Per-tool execution timeout |

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
| `maxToolResultCharacters` | nil | Truncates tool results beyond this length |

**Context budget:**

| Property | Default | Description |
|---|---|---|
| `contextBudget` | nil | ``ContextBudgetConfig`` enabling visibility injection, soft-threshold advisories, and the `prune_context` tool |

See <doc:ContextManagement> for details on compaction and context budgets.

## AgentResult

``AgentResult`` is returned by `run(userMessage:history:context:tokenBudget:requestContext:)` on ``Agent``.

| Field | Type | Description |
|---|---|---|
| `content` | `String` | The text passed to the finish tool |
| `finishReason` | ``FinishReason`` | `.completed`, `.error`, or `.custom(_:)` |
| `totalTokenUsage` | ``TokenUsage`` | Accumulated input/output tokens across all iterations |
| `iterations` | `Int` | Number of generate/tool-call cycles executed |
| `history` | `[ChatMessage]` | Full conversation including system prompt, user messages, assistant responses, and tool results |

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
