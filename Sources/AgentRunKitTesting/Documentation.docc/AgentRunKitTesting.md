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

## Topics

### Testing

- ``TestLLMClient``
