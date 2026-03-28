# Context Management

Managing token budgets and conversation history in long-running agent sessions.

## Overview

LLM context windows are finite. A long agent session with many tool calls can exhaust the window, causing provider errors or degraded output quality. AgentRunKit provides layered controls to keep conversations within budget: automatic compaction, tool result truncation, message-count limits, and real-time budget tracking.

## Setup

Two values drive compaction. Set `contextWindowSize` on the client so the framework knows the model's limit, and set `compactionThreshold` on ``AgentConfiguration`` to define when compaction fires:

```swift
let client = OpenAIClient(
    apiKey: "sk-...",
    model: "gpt-4o",
    baseURL: OpenAIClient.openAIBaseURL,
    contextWindowSize: 128_000
)

let config = AgentConfiguration(
    maxMessages: 40,
    compactionThreshold: 0.75,
    maxToolResultCharacters: 8_000,
    contextBudget: ContextBudgetConfig(
        softThreshold: 0.8,
        enableVisibility: true
    )
)

let agent = Agent(client: client, tools: tools, configuration: config)
```

When token usage reaches 75% of the window, the agent compacts the conversation automatically.

## Two-Phase Compaction Cascade

Compaction runs as a two-phase cascade. The agent tries the cheapest strategy first and escalates only if needed.

**Phase 1: Observation pruning (free).** Old tool results before the most recent assistant message are replaced with short placeholders:

```
[Result from search_web: Top 3 results for "Swift concurrency"... (pruned)]
```

If pruning reduces tool-result volume by more than 20%, the agent uses the pruned history and skips phase 2.

**Phase 2: LLM summarization (one API call).** The agent sends the conversation to the LLM with a checkpoint prompt asking it to produce a detailed handoff summary. The summary replaces the middle of the conversation, preserving the system prompt, initial user message, and the most recent exchange. Customize the checkpoint prompt with ``AgentConfiguration/compactionPrompt``.

**Fallback.** If summarization fails (network error, provider outage), the agent falls back to message-count truncation via ``AgentConfiguration/maxMessages``.

## Tool Result Truncation

``AgentConfiguration/maxToolResultCharacters`` applies middle-out truncation to large tool results at recording time. The prefix and suffix of the result are preserved, with the middle replaced by a `...[truncated]...` marker. This keeps individual results bounded before they enter the conversation history.

## Message-Count Truncation

``AgentConfiguration/maxMessages`` enforces a simple sliding window. When the history exceeds this count, older messages are dropped. The system prompt is always preserved. The truncation algorithm detects tool call/response pairs and avoids cutting between them, which would produce an invalid conversation.

## ContextBudget

``ContextBudget`` is a snapshot of token utilization after each model turn. It provides:

| Property | Description |
|---|---|
| `windowSize` | The model's context window size in tokens |
| `currentUsage` | Tokens consumed by the current conversation |
| `utilization` | `currentUsage / windowSize`, clamped to [0, 1] |
| `remaining` | Tokens still available |
| `isAboveSoftThreshold` | Whether utilization has crossed the configured threshold |

Use ``ContextBudget/formatted(_:)`` to render a human-readable annotation, either with the built-in `.standard` format or a `.custom` template using `{usage}` and `{window}` placeholders.

## ContextBudgetConfig

``ContextBudgetConfig`` controls budget-related features on ``AgentConfiguration``:

| Property | Default | Description |
|---|---|---|
| `softThreshold` | nil | Utilization ratio (0, 1) that triggers a `.budgetAdvisory` event |
| `enablePruneTool` | false | Injects a `prune_context` tool the model can call to shed old observations |
| `enableVisibility` | false | Appends a token usage annotation to history after each turn |
| `visibilityFormat` | `.standard` | Format for the visibility annotation |

Budget features that track usage require the client to report both `contextWindowSize` and per-turn `tokenUsage`.

## Streaming Events

Three ``StreamEvent`` cases surface budget state during streaming:

- `.compacted(totalTokens:windowSize:)`: Fired after a successful compaction pass.
- `.budgetUpdated(budget:)`: Emitted after each provider response when a ``ContextBudget`` snapshot is available.
- `.budgetAdvisory(budget:)`: Emitted once when utilization first crosses the configured soft threshold.

These events propagate through sub-agent chains. See <doc:SubAgents> for details on recursive event propagation.

## See Also

- <doc:AgentAndChat>
- <doc:SubAgents>
