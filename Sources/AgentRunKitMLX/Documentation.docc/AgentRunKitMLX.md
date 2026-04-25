# ``AgentRunKitMLX``

On-device LLM inference via MLX.

## Overview

AgentRunKitMLX bridges AgentRunKit to `mlx-swift-lm` through ``MLXClient``. Use it when an app wants local generation with the same AgentRunKit messages, tools, streaming deltas, and agent loop used by cloud clients.

MLX generation supports tool calls, streaming, request parameter overrides through `RequestContext.extraFields`, and reasoning extraction from `<think>` tags. Structured output via `ResponseFormat` is not supported by this client.

## Topics

### Client

- ``MLXClient``
