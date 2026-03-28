# Structured Output

Get typed, schema-constrained responses from LLMs.

## Overview

Structured output forces the model to return valid JSON conforming to a schema you define. The response is decoded into a Swift type at the call site. This relies on ``ResponseFormat``, which wraps a ``JSONSchema`` with strict mode enabled.

### Chat (Automatic Decoding)

``Chat`` handles schema attachment, request dispatch, and JSON decoding in one call:

```swift
struct WeatherReport: Codable, SchemaProviding, Sendable {
    let city: String
    let temperatureF: Double
    let conditions: String
}

let chat = Chat<EmptyContext>(client: client)
let (report, history) = try await chat.send(
    "Weather in Paris?",
    returning: WeatherReport.self
)
print(report.conditions) // "Partly cloudy"
```

### LLMClient (Manual Decoding)

Use ``LLMClient/generate(messages:tools:responseFormat:requestContext:)`` directly when you need full control:

```swift
let response = try await client.generate(
    messages: [.user("Weather in Paris?")],
    tools: [],
    responseFormat: .jsonSchema(WeatherReport.self)
)
let report = try JSONDecoder().decode(
    WeatherReport.self,
    from: Data(response.content.utf8)
)
```

## SchemaProviding Protocol

``SchemaProviding`` has one requirement: a static ``SchemaProviding/jsonSchema`` property returning a ``JSONSchema``. For types that also conform to `Decodable`, the default implementation uses ``SchemaDecoder`` to infer the schema automatically. The `WeatherReport` above needs no manual schema code.

Optional properties become nullable via `anyOf` and are excluded from the `required` array.

## Custom Schemas

When inference is insufficient, implement the property directly:

```swift
struct SearchQuery: Codable, SchemaProviding, Sendable {
    let query: String
    let maxResults: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "query": .string(description: "Search terms"),
                "maxResults": .integer(description: "Result limit, 1-100"),
            ],
            required: ["query", "maxResults"]
        )
    }
}
```

## JSONSchema Cases

``JSONSchema`` is an indirect enum: `.string`, `.integer`, `.number`, `.boolean`, `.array(items:)`, `.object(properties:required:)`, `.null`, and `.anyOf`. String supports optional `enumValues` for constrained enums. `anyOf` is used internally for optional properties.

## Inspecting Inferred Schemas

Use ``SchemaDecoder`` to see what schema a type produces:

```swift
let schema = try SchemaDecoder.decode(WeatherReport.self)
// .object(properties: ["city": .string(), ...], required: ["city", ...])
```

## Provider Support

Not all providers support structured output via `responseFormat`.

| Provider | Supported |
|---|---|
| ``OpenAIClient`` | Yes |
| ``GeminiClient`` | Yes |
| ``VertexGoogleClient`` | Yes |
| ``ResponsesAPIClient`` | Yes |
| ``AnthropicClient`` | No |
| ``VertexAnthropicClient`` | No |

Providers that do not support structured output will ignore the response format or throw.

## See Also

- <doc:DefiningTools>
- <doc:AgentAndChat>
- <doc:LLMProviders>
