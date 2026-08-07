# ``AgentRunKitTesting``

Offline testing utilities for AgentRunKit agents.

## Overview

AgentRunKitTesting provides ``TestLLMClient``, a schema-walking LLM client that generates valid tool call arguments from JSON schemas without making network requests. Use it to test agent loops, tool execution, and streaming behavior in isolation.

## Testing Custom Completion

An agent built with a `completionTool:` and ordinary tools requires the matching `completionToolName:` on its client. Without it the client calls every advertised tool in one batch, including the completion tool. The agent rejects that batch as an exclusivity violation and executes nothing, and the run ends at `maxIterationsReached` carrying the violation feedback in its history instead of a result.

```swift
let client = TestLLMClient(completionToolName: "publish_report")
let agent = Agent(client: client, tools: [searchTool], completionTool: publishTool)
```

With the name set, the client calls the ordinary tools first and then calls the completion tool alone once their results are in. If a tool-carrying request arrives without a definition matching the configured name, the client fails a precondition rather than silently producing a different batch; requests that advertise no tools at all — context-compaction summaries, or a `Chat` without tools — are unaffected.

The setting belongs to one client instance. A sub-agent or a tool-equipped `Chat` sharing the same configured client sends tool-carrying requests that lack the completion definition and trips that precondition — give child agents their own unconfigured ``TestLLMClient``.

## Tool Call Identifiers

Every call the client mints carries a turn-scoped id, where the turn is the number of assistant messages in the request: `test_call_<turn>_<index>` for an ordinary tool, `test_completion_<turn>` for a completion tool, `test_finish_<turn>` for the built-in finish tool. Ids stay deterministic across runs and unique within one conversation, matching the unique-per-conversation ids real providers mint, so a history the client produced replays without duplicate-id rejections. A completion attempt that fails and is retried therefore arrives under a fresh id rather than colliding with the attempt before it.

The client calls its ordinary tools once per conversation turn, and a context-budget advisory does not start a new one. The framework appends those advisories as a user message directly after a tool result, and the client reads any user message in that position as part of the prior turn, so it completes instead of repeating tools it has already called. The same rule applies to a supplied history that ends with a resolved tool batch followed by a new user message: the client treats that batch as this cycle's tool work and moves straight to completion.

## Topics

### Testing

- ``TestLLMClient``
