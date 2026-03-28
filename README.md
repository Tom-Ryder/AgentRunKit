# AgentRunKit

<p align="center">
  <img src="assets/logo-dark.png" alt="AgentRunKit" width="280">
</p>

<p align="center">
  <a href="https://github.com/Tom-Ryder/AgentRunKit/actions/workflows/ci.yml"><img src="https://github.com/Tom-Ryder/AgentRunKit/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/Platforms-iOS%2018%20%7C%20macOS%2015-blue" alt="Platforms">
  <img src="https://img.shields.io/badge/On--Device-MLX%20%7C%20Foundation%20Models-8B5CF6" alt="On-Device MLX + Foundation Models">
  <img src="https://img.shields.io/badge/SPM-compatible-brightgreen" alt="SPM">
  <img src="https://img.shields.io/badge/License-MIT-lightgrey" alt="License">
  <a href="https://swiftpackageindex.com/Tom-Ryder/AgentRunKit/documentation/agentrunkit"><img src="https://img.shields.io/badge/Documentation-DocC-blue" alt="Documentation"></a>
</p>

<p align="center">
  A lightweight Swift 6 framework for building LLM-powered agents with type-safe tool calling.
</p>

<p align="center">
  <b>Zero dependencies</b> · <b>Full Sendable</b> · <b>Async/await</b> · <b>Cloud + Local</b> · <b>MCP</b>
</p>

---

## Quick Start

```swift
import AgentRunKit

let client = OpenAIClient(apiKey: "sk-...", model: "gpt-4o", baseURL: OpenAIClient.openAIBaseURL)

let weatherTool = try Tool<WeatherParams, String, EmptyContext>(
    name: "get_weather",
    description: "Get the current weather"
) { params, _ in
    "72°F and sunny in \(params.city)"
}

let agent = Agent(client: client, tools: [weatherTool])
let result = try await agent.run(userMessage: "What's the weather in SF?", context: EmptyContext())
print(result.content)
```

---

## Documentation

Full documentation including guides and API reference is available on [Swift Package Index](https://swiftpackageindex.com/Tom-Ryder/AgentRunKit/documentation/agentrunkit).

---

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Tom-Ryder/AgentRunKit.git", from: "1.20.1")
]
```

```swift
.target(name: "YourApp", dependencies: ["AgentRunKit"])
```

For on-device inference, additional targets are available:

- `AgentRunKitMLX` for MLX on Apple Silicon (requires [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) as a dependency)
- `AgentRunKitFoundationModels` for Apple Foundation Models (iOS 26+ / macOS 26+, no external dependencies)

---

## Features

- Agent loop with configurable iteration limits and token budgets
- Streaming with `AsyncThrowingStream` and `@Observable` SwiftUI wrapper
- Type-safe tools with compile-time JSON schema validation
- Sub-agent composition with depth control and streaming propagation
- Context management: automatic compaction, pruning, token budgets
- Structured output with JSON schema constraints
- Multimodal input: images, audio, video, PDF
- Text-to-speech with concurrent chunking and MP3 concatenation
- MCP client: stdio transport, tool discovery, JSON-RPC
- Extended thinking / reasoning model support

---

## Providers

| Provider | Description |
|----------|-------------|
| `OpenAIClient` | OpenAI and compatible APIs (OpenRouter, Groq, Together, Ollama) |
| `AnthropicClient` | Anthropic Messages API |
| `GeminiClient` | Google Gemini API |
| `VertexAnthropicClient` | Anthropic models on Google Vertex AI |
| `VertexGoogleClient` | Google models on Vertex AI |
| `ResponsesAPIClient` | OpenAI Responses API |
| `FoundationModelsClient` | Apple on-device (macOS 26+ / iOS 26+) |
| `MLXClient` | On-device via MLX on Apple Silicon |

---

## Requirements

| Platform | Version |
|----------|---------|
| iOS | 18.0+ |
| macOS | 15.0+ |
| Swift | 6.0+ |
| Xcode | 16+ |

---

## License

MIT License. See [LICENSE](LICENSE) for details.
