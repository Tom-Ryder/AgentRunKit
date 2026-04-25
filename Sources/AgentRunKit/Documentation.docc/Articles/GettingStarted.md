# Getting Started

Install AgentRunKit, define a tool, and run your first agent loop.

## Add the Dependency

In your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Tom-Ryder/AgentRunKit.git", from: "2.4.0")
]
```

Then add the library to your target:

```swift
.target(name: "YourApp", dependencies: ["AgentRunKit"])
```

## Your First Agent

```swift
import AgentRunKit

struct WeatherParams: Codable, SchemaProviding, Sendable {
    let city: String
}

let client = OpenAIClient.openAI(apiKey: "sk-...", model: "gpt-5.4")

let weatherTool = try Tool<WeatherParams, String, EmptyContext>(
    name: "get_weather",
    description: "Get the current weather for a city"
) { params, _ in
    "72\u{00B0}F and sunny in \(params.city)"
}

let agent = Agent(client: client, tools: [weatherTool])
let result = try await agent.run(
    userMessage: "What's the weather in San Francisco?",
    context: EmptyContext()
)

if let content = result.content {
    print(content)
}
print(result.totalTokenUsage.total) // Total tokens consumed
print(result.iterations)            // Number of generate/tool cycles
```

## What Happened

``Agent`` sent the user message to the LLM, which responded with a `get_weather` tool call. The agent executed the tool, fed the result back, and the LLM called the built-in `finish` tool with its final answer. The returned ``AgentResult`` contains optional finish text, cumulative ``TokenUsage``, the terminal ``FinishReason``, and the number of loop iterations. If the loop hits `maxIterations` or `tokenBudget` before `finish`, `run()` still returns an ``AgentResult`` and `content` is `nil`.

## Next Steps

- <doc:AgentAndChat>: ``Agent`` loop semantics, ``Chat`` for conversations, configuration options.
- <doc:DefiningTools>: ``Tool`` parameters, ``SchemaProviding``, custom context types.
