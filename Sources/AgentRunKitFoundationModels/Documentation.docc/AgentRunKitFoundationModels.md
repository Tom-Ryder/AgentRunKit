# ``AgentRunKitFoundationModels``

On-device LLM inference via Apple's Foundation Models framework.

## Overview

AgentRunKitFoundationModels bridges AgentRunKit to Apple's on-device foundation model. Use
`Agent.onDevice(tools:context:instructions:)` as the primary entry point, or construct a
``FoundationModelsClient`` directly. Single-turn generation and streaming run on-device with no network access
required. Requires macOS 26+ or iOS 26+ with Apple Intelligence enabled.

`Chat` and direct ``FoundationModelsClient`` usage are supported for single-turn text interactions: `Chat.send()`
returns an `AssistantMessage` with text in `content`, and `Chat.stream()` terminates on content-only iterations the
same way it does for cloud clients. Histories must contain exactly one non-empty text user prompt, optionally
preceded by system instructions. Multi-turn histories, AgentRunKit tool-loop history, and non-text multimodal input
are rejected until AgentRunKit maps histories into Foundation Models `Transcript` values or implements history
linearization.

## Topics

### Client

- ``FoundationModelsClient``
