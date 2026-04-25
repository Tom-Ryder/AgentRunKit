# Context Management

Managing token budgets and conversation history in long-running agent sessions.

## Overview

LLM context windows are finite. A long agent session with many tool calls can exhaust the window, causing provider errors or degraded output quality. AgentRunKit provides layered controls to keep conversations within budget: automatic compaction, tool result truncation, message-count limits, and real-time budget tracking.

## Setup

Two values drive compaction. Set `contextWindowSize` on the client so the framework knows the model's limit, and set `compactionThreshold` on ``AgentConfiguration`` to define when compaction fires:

```swift
let client = OpenAIClient.openAI(
    apiKey: "sk-...",
    model: "gpt-5.4",
    contextWindowSize: 1_050_000
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

**Phase 2: LLM summarization (one API call).** The agent sends the conversation to the LLM with a checkpoint prompt asking it to produce a detailed handoff summary. The summary request does not expose regular tools, and the response is accepted only when it contains non-empty text with no tool calls. The summary replaces the middle of the conversation, preserving the system prompt, initial user message, and the most recent exchange. Customize the checkpoint prompt with ``AgentConfiguration/compactionPrompt``.

**Fallback.** If summarization fails (network error, provider outage, empty summary, or tool-call response), the agent falls back to message-count truncation via ``AgentConfiguration/maxMessages``.

## Reactive Prompt-Too-Long Recovery

When a provider rejects a request because the prompt exceeds the context window, the framework attempts one-shot recovery before propagating the error.

**Agent** uses the full compaction cascade reactively: message-count truncation, observation pruning, and LLM-based summarization (if `compactionThreshold` is configured). Both `run()` and `stream()` share this behavior. Streaming recovery is gated on a pre-output invariant: retry is attempted only if no events were yielded to the consumer before the error. If partial content has already been emitted, the error propagates to avoid delivering duplicate or inconsistent output.

**Chat** uses truncation-only recovery. When a `send()` or `stream()` call hits a prompt-too-long error, the framework halves the message count (preserving the system prompt and tool-call/result pairing) and retries once. Chat has no compactor, no pruning, and no summarization. If the halved list is still too large, the error propagates.

Recovery is always one-shot: if the retry also fails, the error propagates. This prevents infinite retry loops on conversations that are fundamentally too large.

## Tool Result Truncation

``AgentConfiguration/maxToolResultCharacters`` is the default limit for tool result truncation. When a tool result exceeds this length, middle-out truncation preserves the prefix and suffix while replacing the middle with a truncation marker sized to fit within the configured limit.

Individual tools can override this default by setting ``AnyTool/maxResultCharacters``. When a tool declares its own limit, that value governs instead of the global default. This lets verbose tools (search, shell output) use tighter limits while tools that need full output (file edits, write confirmations) declare larger ones. Both ``Agent`` and ``Chat`` honor per-tool limits.

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

Budget features require the client to report `contextWindowSize`. Per-turn `tokenUsage` is consumed when the provider reports it; iterations that return nil usage (transient SSE chunk drops, proxies that omit the usage block) are skipped and the next iteration with reported usage resumes tracking.

## Streaming Events

Three ``StreamEvent`` cases surface budget state during streaming:

- ``StreamEvent/Kind/compacted(totalTokens:windowSize:)``: Fired after a successful compaction pass.
- ``StreamEvent/Kind/budgetUpdated(budget:)``: Emitted after each provider response when a ``ContextBudget`` snapshot is available.
- ``StreamEvent/Kind/budgetAdvisory(budget:)``: Emitted once when utilization first crosses the configured soft threshold.

These events propagate through sub-agent chains. See <doc:SubAgents> for details on recursive event propagation.

## See Also

- <doc:AgentAndChat>
- <doc:SubAgents>
