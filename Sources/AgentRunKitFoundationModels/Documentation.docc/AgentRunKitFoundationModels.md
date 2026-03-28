# ``AgentRunKitFoundationModels``

On-device LLM inference via Apple's Foundation Models framework.

## Overview

AgentRunKitFoundationModels bridges AgentRunKit to Apple's on-device foundation model. Use `Agent.onDevice(tools:context:instructions:)` as the primary entry point, or construct a ``FoundationModelsClient`` directly. The same tools, agent loop, and streaming API work on-device with no network access required. Requires macOS 26+ or iOS 26+ with Apple Intelligence enabled.

## Topics

### Client

- ``FoundationModelsClient``
