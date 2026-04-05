# ``AgentRunKitFoundationModels``

On-device LLM inference via Apple's Foundation Models framework.

## Overview

AgentRunKitFoundationModels bridges AgentRunKit to Apple's on-device foundation model. Use `Agent.onDevice(tools:context:instructions:)` as the primary entry point, or construct a ``FoundationModelsClient`` directly. The same tools, agent loop, and streaming API work on-device with no network access required. Requires macOS 26+ or iOS 26+ with Apple Intelligence enabled.

``Chat`` and direct ``FoundationModelsClient`` usage are supported for single-turn interactions: `Chat.send()` returns an `AssistantMessage` with text in `content`, and `Chat.stream()` terminates on content-only iterations the same way it does for cloud clients. Multi-turn conversations are currently limited: only the most recent user turn is forwarded to the on-device session, so prior assistant and tool messages are not yet preserved across turns. Full history linearization is tracked as a follow-up.

## Topics

### Client

- ``FoundationModelsClient``
