# Defining Tools

Give agents the ability to call your code by defining typed tools.

## Overview

Tools let an LLM invoke Swift functions. You define the parameter type, the return type, and an executor closure. The framework handles JSON schema generation, argument decoding, and result encoding.

## The Tool Type

``Tool`` is generic over three type parameters:

- `P`: the parameters type, conforming to `Codable & SchemaProviding & Sendable`
- `O`: the output type, conforming to `Codable & Sendable`
- `C`: the context type, conforming to ``ToolContext``

```swift
import AgentRunKit

struct WeatherParams: Codable, SchemaProviding, Sendable {
    let city: String
    let unit: String?
}

let weatherTool = try Tool<WeatherParams, String, EmptyContext>(
    name: "get_weather",
    description: "Get the current weather for a city"
) { params, _ in
    "72F and sunny in \(params.city)"
}
```

The initializer is throwing. It calls ``SchemaProviding/validateSchema()`` at construction time to catch schema inference failures early rather than at runtime.

## Auto-Schema Inference

Any type that conforms to both `Decodable` and ``SchemaProviding`` gets automatic JSON schema generation. The default implementation uses ``SchemaDecoder`` to walk the `Decoder` protocol and produce a ``JSONSchema``:

```swift
// WeatherParams above automatically generates:
// {
//   "type": "object",
//   "properties": {
//     "city": { "type": "string" },
//     "unit": { "anyOf": [{ "type": "string" }, { "type": "null" }] }
//   },
//   "required": ["city"]
// }
```

Optional properties become nullable via `anyOf` and are excluded from the `required` array.

## Manual Schema Override

For cases where inferred schemas are insufficient, implement ``SchemaProviding/jsonSchema`` directly:

```swift
struct SearchParams: Codable, SchemaProviding, Sendable {
    let query: String
    let maxResults: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "query": .string(description: "Search query"),
                "maxResults": .integer(description: "Max results to return"),
            ],
            required: ["query", "maxResults"]
        )
    }
}
```

## ToolContext for Dependency Injection

The ``ToolContext`` protocol lets you pass dependencies into tool executors. It has a single requirement, `withParentHistory(_:)`, which sub-agents use to inherit conversation history.

```swift
struct AppContext: ToolContext {
    let database: Database
    let userId: String

    func withParentHistory(_ history: [ChatMessage]) -> Self {
        self // stateless context, history not needed
    }
}

let dbTool = try Tool<QueryParams, [Row], AppContext>(
    name: "query_db",
    description: "Query the database"
) { params, context in
    try await context.database.query(params.sql)
}
```

For tools that need no context, use ``EmptyContext``.

## ToolResult

Tool executors return their `O` type, which the framework encodes to JSON and wraps in a ``ToolResult``. When implementing ``AnyTool`` directly, you return ``ToolResult`` yourself:

- ``ToolResult/success(_:)`` for successful output
- ``ToolResult/error(_:)`` for a recoverable error the LLM should see

```swift
ToolResult.success("{\"temperature\": 72}")
ToolResult.error("City not found")
```

## Tool Classification

``Tool`` exposes optional metadata properties that describe a tool's behavior:

```swift
let searchTool = try Tool<SearchParams, String, EmptyContext>(
    name: "search",
    description: "Search the database",
    isConcurrencySafe: true,
    maxResultCharacters: 5_000,
    strict: true,
    executor: { params, _ in performSearch(params.query) }
)
```

| Property | Default | Description |
|---|---|---|
| `isConcurrencySafe` | `false` | Whether the tool can safely run concurrently with other tools. ``Agent`` honors this: unsafe tools form exclusive barriers in the execution schedule. |
| `maxResultCharacters` | `nil` | Per-tool override for ``AgentConfiguration/maxToolResultCharacters``. When set, this limit governs instead of the global default. |
| `strict` | `nil` | Whether the provider should enforce strict JSON Schema adherence on the tool's arguments. Preserved on first-party OpenAI Chat and Responses function tools where supported; unsupported providers reject strict schemas instead of dropping the request. |

Defaults are fail-closed: tools are assumed non-concurrent unless explicitly declared otherwise. Direct ``AnyTool`` conformers can override these properties in the same way.

When ``Agent`` executes sibling tool calls, it groups contiguous `isConcurrencySafe` calls into concurrent waves and treats each unsafe or unresolved call as an exclusive barrier. ``Chat`` executes tool calls sequentially regardless of this property.

## Per-Tool Timeout

Override ``AgentConfiguration/toolTimeout`` for a specific tool by passing `toolTimeout: Duration?` to ``Tool/init(name:description:isConcurrencySafe:maxResultCharacters:strict:toolTimeout:executor:)``. `nil` (the default) inherits the agent's configured timeout. Set an explicit `Duration` to apply a per-tool ceiling:

```swift
let deepPoll = try Tool<PollParams, PollResult, AppContext>(
    name: "long_poll",
    description: "Polls an upstream service",
    toolTimeout: .minutes(30),
    executor: { params, ctx in try await upstream.poll(params) }
)
```

Both ``Agent`` and ``Chat`` honor the per-tool override. ``SubAgentTool`` exposes the same `toolTimeout` parameter with identical semantics.

Tools that don't declare a timeout inherit the agent's or chat's configured default. Tools surfaced through other adapters do not participate: ``MCPTool`` falls back to the global because the MCP wire format carries no timeout metadata, and tools invoked through `AgentRunKitFoundationModels` are dispatched inside Apple's on-device session and bypass this machinery entirely.

## Topics

### Core Types

- ``Tool``
- ``AnyTool``
- ``ToolContext``
- ``ToolResult``
- ``EmptyContext``

### Schema

- ``SchemaProviding``
- ``JSONSchema``
- ``SchemaDecoder``

### Related

- <doc:GettingStarted>
- <doc:AgentAndChat>
- <doc:StructuredOutput>
