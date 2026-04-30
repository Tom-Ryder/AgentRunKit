# Sub-Agents

Compose agents as tools with ``SubAgentTool``, enabling an orchestrator agent to delegate work to specialized child agents.

## Overview

``SubAgentTool`` wraps an ``Agent`` as a callable tool. When the parent agent invokes the tool, it runs the child agent's full loop and returns the result. Depth tracking prevents unbounded recursion, token budgets constrain child costs, and streaming events propagate through the hierarchy.

## Defining a SubAgentTool

``SubAgentTool`` has two generic parameters:

| Parameter | Constraint | Role |
|---|---|---|
| `P` | `Codable & SchemaProviding & Sendable` | Parameters the LLM provides when calling the tool |
| `InnerContext` | ``ToolContext`` | The application context type, wrapped by ``SubAgentContext`` |

The child agent's context type is always `SubAgentContext<InnerContext>`.

### Example

```swift
import AgentRunKit

// 1. Define the parameters the LLM will provide.
struct ResearchParams: Codable, SchemaProviding, Sendable {
    let topic: String
    let maxSources: Int
}

// 2. Define a context for your application state.
struct AppContext: ToolContext {
    let apiKey: String
}

// 3. Build the child agent.
let searchTool = try Tool<SearchParams, String, SubAgentContext<AppContext>>(
    name: "web_search",
    description: "Search the web"
) { params, ctx in
    "Results for \(params.query) using key \(ctx.inner.apiKey)"
}

let researcher = Agent<SubAgentContext<AppContext>>(
    client: researchClient,
    tools: [searchTool],
    configuration: AgentConfiguration(systemPrompt: "You are a research assistant.")
)

// 4. Wrap it as a tool.
let researchTool = try SubAgentTool<ResearchParams, AppContext>(
    name: "research",
    description: "Research a topic using web search",
    agent: researcher,
    tokenBudget: 4000,
    inheritParentMessages: true,
    systemPromptBuilder: { params in
        "Research '\(params.topic)'. Use at most \(params.maxSources) sources."
    },
    messageBuilder: { params in
        "Research the following topic: \(params.topic)"
    }
)

// 5. Give it to the orchestrator.
let orchestrator = Agent<SubAgentContext<AppContext>>(
    client: orchestratorClient,
    tools: [researchTool]
)

let ctx = SubAgentContext(inner: AppContext(apiKey: "sk-..."), maxDepth: 3)
let result = try await orchestrator.run(userMessage: "Write a report on quantum computing.", context: ctx)
```

## SubAgentContext

``SubAgentContext`` wraps your application context and tracks nesting depth.

| Property | Type | Description |
|---|---|---|
| `inner` | `C` | The wrapped application context |
| `currentDepth` | `Int` | Current nesting level (starts at 0) |
| `maxDepth` | `Int` | Maximum allowed depth (default 3, minimum 1) |

When a sub-agent executes, ``SubAgentTool`` calls `descending()` to increment the depth. If `currentDepth` equals `maxDepth`, execution throws ``AgentError/maxDepthExceeded(depth:)``.

`withParentHistory(_:)` attaches the parent's conversation history to the context. The child agent receives this history when `inheritParentMessages` is enabled, with system messages filtered out.

## Configuration Options

**Token budgets.** The `tokenBudget` parameter caps the child agent's total token usage across all iterations. This prevents a child from consuming the parent's budget.

**System prompt override.** `systemPromptBuilder` receives the decoded `P` and returns a system prompt that replaces the child agent's configured prompt for that invocation. Use this to specialize the child based on the parent's request.

**Parent message inheritance.** When `inheritParentMessages` is `true`, the parent's conversation history (excluding system messages) is forwarded to the child. This gives the child agent conversational context without re-prompting.

**Tool timeout.** `toolTimeout` overrides the parent agent's default tool timeout for this sub-agent invocation. `nil` (the default) inherits the parent's ``AgentConfiguration/toolTimeout``.

**Tool metadata.** `SubAgentTool` also exposes `isConcurrencySafe` and `maxResultCharacters`, matching `Tool`. ``Agent`` honors `isConcurrencySafe` for scheduling: sibling sub-agents default to sequential execution and must opt in to concurrent execution.

## Streaming Propagation

When the parent agent streams via `stream()`, sub-agent events propagate through the hierarchy as ``StreamEvent`` cases:

| Event | When |
|---|---|
| ``StreamEvent/Kind/subAgentStarted(toolCallId:toolName:)`` | Child agent begins execution |
| ``StreamEvent/Kind/subAgentEvent(toolCallId:toolName:event:)`` | Each event from the child, recursively nested for deeper hierarchies |
| ``StreamEvent/Kind/subAgentCompleted(toolCallId:toolName:result:)`` | Child agent finishes |

The `subAgentEvent` case is `indirect`, so a three-level hierarchy produces nested events: the grandchild's deltas appear wrapped twice. The nested child event preserves its own envelope metadata, including its own `id` and `timestamp`. See <doc:StreamingAndSwiftUI> for consuming these events in SwiftUI.

## Error Propagation

If a child agent finishes with ``FinishReason/error``, the ``SubAgentTool`` returns a ``ToolResult`` with `isError: true`. Structural child terminal reasons, including ``FinishReason/maxIterationsReached(limit:)`` and ``FinishReason/tokenBudgetExceeded(budget:used:)``, are also surfaced to the parent as tool errors with standardized messages. The parent agent continues to see these as failed tool calls and can retry or handle the failure explicitly.

## See Also

- <doc:AgentAndChat>
- <doc:ContextManagement>
- <doc:StreamingAndSwiftUI>
