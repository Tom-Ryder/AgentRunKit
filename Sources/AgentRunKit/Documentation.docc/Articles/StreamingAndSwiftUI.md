# Streaming and SwiftUI

Real-time token delivery and tool progress via ``StreamEvent``, with an `@Observable` wrapper for SwiftUI.

## Overview

``Agent`` supports two modes: `run()` returns an ``AgentResult`` when the loop finishes, `stream()` yields events as they happen. ``AgentStream`` bridges the stream into SwiftUI via `@Observable` properties.

## Agent Streaming

Call `stream()` on an ``Agent`` to get an `AsyncThrowingStream<StreamEvent, Error>`:

```swift
let stream = agent.stream(userMessage: "Summarize this paper.", context: ctx)
for try await event in stream {
    switch event {
    case .delta(let text):
        print(text, terminator: "")
    case .toolCallStarted(let name, _):
        print("\n[calling \(name)...]")
    case .toolCallCompleted(_, let name, let result):
        print("[\(name) returned \(result.content)]")
    case .finished(let usage, _, _, _):
        print("\nTokens: \(usage.total)")
    default:
        break
    }
}
```

The stream yields events until the model calls `finish` or an error occurs. Cancelling the consuming task cancels the underlying LLM request.

## StreamEvent Cases

``StreamEvent`` is a flat enum. Cases are grouped below by category.

**Content:**

| Case | Payload | Description |
|---|---|---|
| `.delta` | `String` | Incremental text token from the model |
| `.reasoningDelta` | `String` | Incremental reasoning/thinking token |

**Tool calls:**

| Case | Payload | Description |
|---|---|---|
| `.toolCallStarted` | `name`, `id` | Tool execution is beginning |
| `.toolCallCompleted` | `id`, `name`, ``ToolResult`` | Tool execution finished |

**Audio:**

| Case | Payload | Description |
|---|---|---|
| `.audioData` | `Data` | Raw audio bytes (streaming) |
| `.audioTranscript` | `String` | Transcript of generated audio |
| `.audioFinished` | `id`, `expiresAt`, `Data` | Final audio segment |

**Sub-agents:**

| Case | Payload | Description |
|---|---|---|
| `.subAgentStarted` | `toolCallId`, `toolName` | A sub-agent began executing |
| `.subAgentEvent` | `toolCallId`, `toolName`, ``StreamEvent`` | Recursive event from a nested agent |
| `.subAgentCompleted` | `toolCallId`, `toolName`, ``ToolResult`` | Sub-agent finished. See <doc:SubAgents>. |

**Lifecycle:**

| Case | Payload | Description |
|---|---|---|
| `.finished` | ``TokenUsage``, content, reason, history | Agent loop completed |
| `.iterationCompleted` | ``TokenUsage``, iteration number | One generate/tool-call cycle completed |
| `.compacted` | `totalTokens`, `windowSize` | Context was compacted to fit the window |
| `.budgetUpdated` | ``ContextBudget`` | Latest budget snapshot after a provider response |
| `.budgetAdvisory` | ``ContextBudget`` | Soft threshold was crossed |

## AgentStream for SwiftUI

``AgentStream`` is an `@Observable`, `@MainActor` class that consumes a stream and exposes collected state. Create one from an ``Agent``:

```swift
@State private var stream = AgentStream(agent: agent)
```

**Properties:**

| Property | Type | Description |
|---|---|---|
| `content` | `String` | Accumulated text from `.delta` events |
| `reasoning` | `String` | Accumulated reasoning from `.reasoningDelta` events |
| `isStreaming` | `Bool` | True while a stream is active |
| `error` | `(any Error & Sendable)?` | Set if the stream throws |
| `tokenUsage` | ``TokenUsage``? | Final cumulative usage from `.finished` |
| `finishReason` | `FinishReason?` | Reason from `.finished` |
| `history` | `[ChatMessage]` | Full conversation history from `.finished` |
| `toolCalls` | [``ToolCallInfo``] | Tool calls with live state (`.running`, `.completed`, `.failed`) |
| `iterationUsages` | [``TokenUsage``] | Per-iteration usage, one entry per `.iterationCompleted` |
| `contextBudget` | ``ContextBudget``? | Latest budget snapshot from `.budgetUpdated` |

**Methods:**

- `send(_:history:context:tokenBudget:requestContext:)` cancels any active stream, resets state, and starts a new one.
- `cancel()` cancels the active stream without resetting state.

## SwiftUI Example

```swift
struct ChatView: View {
    @State private var stream = AgentStream(agent: agent)
    @State private var input = ""

    var body: some View {
        VStack {
            ScrollView {
                Text(stream.content)
                ForEach(stream.toolCalls) { call in
                    HStack {
                        Text(call.name)
                        switch call.state {
                        case .running: ProgressView().controlSize(.small)
                        case .completed: Image(systemName: "checkmark.circle")
                        case .failed: Image(systemName: "xmark.circle")
                        }
                    }
                }
            }
            if stream.isStreaming { ProgressView() }
            if let error = stream.error {
                Text(error.localizedDescription).foregroundStyle(.red)
            }
            HStack {
                TextField("Message", text: $input)
                Button("Send") {
                    stream.send(input, context: EmptyContext())
                    input = ""
                }.disabled(stream.isStreaming)
            }
        }
    }
}
```

## Per-Iteration Token Tracking

Each iteration yields `.iterationCompleted` with that iteration's ``TokenUsage``. ``AgentStream`` collects these into `iterationUsages`. The `.finished` event carries the cumulative total.

```swift
for (index, usage) in stream.iterationUsages.enumerated() {
    print("Iteration \(index + 1): \(usage.input)in / \(usage.output)out")
}
```

## See Also

- <doc:AgentAndChat>
- <doc:SubAgents>
- ``StreamEvent``
- ``AgentStream``
- ``ToolCallInfo``
- ``TokenUsage``
