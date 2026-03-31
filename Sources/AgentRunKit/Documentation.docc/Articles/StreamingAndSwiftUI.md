# Streaming and SwiftUI

Real-time token delivery and tool progress via ``StreamEvent``, with an `@Observable` wrapper for SwiftUI.

## Overview

``Agent`` supports two modes: `run()` returns an ``AgentResult`` when the loop finishes, `stream()` yields events as they happen. ``AgentStream`` bridges the stream into SwiftUI via `@Observable` properties.

## Agent Streaming

Call `stream()` on an ``Agent`` to get an `AsyncThrowingStream<StreamEvent, Error>`:

```swift
let stream = agent.stream(
    userMessage: "Summarize this paper.",
    context: ctx,
    approvalHandler: approvalHandler
)
for try await event in stream {
    switch event.kind {
    case .delta(let text):
        print(text, terminator: "")
    case .toolCallStarted(let name, _):
        print("\n[calling \(name)...]")
    case .toolApprovalRequested(let request):
        print("\n[approval needed for \(request.toolName)]")
    case .toolCallCompleted(_, let name, let result):
        print("[\(name) returned \(result.content)]")
    case .finished(let usage, _, let reason, _):
        print("\nTokens: \(usage.total)")
        if let reason {
            print("Reason: \(reason)")
        }
    default:
        break
    }
}
```

Expected terminal states such as max-iterations and token-budget exhaustion arrive as `.finished` events with structural ``FinishReason`` payloads. Only genuine runtime failures throw. Cancelling the consuming task cancels the underlying LLM request and does not guarantee a terminal `.finished` event.

## StreamEvent Envelope

``StreamEvent`` is an envelope struct. The semantic event is carried by ``StreamEvent/kind`` as a ``StreamEvent/Kind`` value.

Every event includes:

| Property | Description |
|---|---|
| ``StreamEvent/id`` | Stable event identity for transcript rendering and correlation |
| ``StreamEvent/timestamp`` | Emission time in UTC |
| ``StreamEvent/sessionID`` | Optional session identity |
| ``StreamEvent/runID`` | Optional run identity |
| ``StreamEvent/parentEventID`` | Optional parent correlation identity |
| ``StreamEvent/kind`` | The semantic payload |

Today, direct `Agent` and `Chat` streams leave `sessionID`, `runID`, and `parentEventID` unset. A future session layer will populate those fields consistently.

## StreamEvent Kinds

Cases are grouped below by category.

**Content:**

| Case | Payload | Description |
|---|---|---|
| ``StreamEvent/Kind/delta(_:)`` | `String` | Incremental text token from the model |
| ``StreamEvent/Kind/reasoningDelta(_:)`` | `String` | Incremental reasoning or thinking token |

**Tool calls:**

| Case | Payload | Description |
|---|---|---|
| ``StreamEvent/Kind/toolCallStarted(name:id:)`` | `name`, `id` | Tool execution is beginning |
| ``StreamEvent/Kind/toolApprovalRequested(_:)`` | ``ToolApprovalRequest`` | A gated tool call is waiting for approval |
| ``StreamEvent/Kind/toolApprovalResolved(toolCallId:decision:)`` | `toolCallId`, ``ToolApprovalDecision`` | Approval was granted, modified, or denied |
| ``StreamEvent/Kind/toolCallCompleted(id:name:result:)`` | `id`, `name`, ``ToolResult`` | Tool execution finished |

**Audio:**

| Case | Payload | Description |
|---|---|---|
| ``StreamEvent/Kind/audioData(_:)`` | `Data` | Raw audio bytes, delivered incrementally |
| ``StreamEvent/Kind/audioTranscript(_:)`` | `String` | Transcript of generated audio |
| ``StreamEvent/Kind/audioFinished(id:expiresAt:data:)`` | `id`, `expiresAt`, `Data` | Final audio payload with metadata |

**Sub-agents:**

| Case | Payload | Description |
|---|---|---|
| ``StreamEvent/Kind/subAgentStarted(toolCallId:toolName:)`` | `toolCallId`, `toolName` | A sub-agent began executing |
| ``StreamEvent/Kind/subAgentEvent(toolCallId:toolName:event:)`` | `toolCallId`, `toolName`, ``StreamEvent`` | Recursive event from a nested agent |
| ``StreamEvent/Kind/subAgentCompleted(toolCallId:toolName:result:)`` | `toolCallId`, `toolName`, ``ToolResult`` | Sub-agent finished. See <doc:SubAgents>. |

**Lifecycle:**

| Case | Payload | Description |
|---|---|---|
| ``StreamEvent/Kind/finished(tokenUsage:content:reason:history:)`` | ``TokenUsage``, content, reason, history | Agent loop completed |
| ``StreamEvent/Kind/iterationCompleted(usage:iteration:)`` | ``TokenUsage``, iteration number | One generate or tool-call cycle completed |
| ``StreamEvent/Kind/compacted(totalTokens:windowSize:)`` | `totalTokens`, `windowSize` | Context was compacted to fit the window |
| ``StreamEvent/Kind/budgetUpdated(budget:)`` | ``ContextBudget`` | Latest budget snapshot after a provider response |
| ``StreamEvent/Kind/budgetAdvisory(budget:)`` | ``ContextBudget`` | Soft threshold was crossed |

## Canonical Transcript JSON

Use ``StreamEventJSONCodec`` when you need stable transcript export or import:

```swift
let data = try StreamEventJSONCodec.encode(event)
let restored = try StreamEventJSONCodec.decode(data)
```

This canonical codec uses the framework's fixed JSON settings for event transcripts. Plain `Codable` conformance remains available for ordinary Swift use, but transcript persistence should go through ``StreamEventJSONCodec``.

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
| `finishReason` | `FinishReason?` | Reason from `.finished`, including structural max-iterations or token-budget limits |
| `history` | `[ChatMessage]` | Full conversation history from `.finished` |
| `toolCalls` | [``ToolCallInfo``] | Top-level and nested tool calls with live state (`.running`, `.awaitingApproval`, `.completed`, `.failed`) |
| `iterationUsages` | [``TokenUsage``] | Per-iteration usage, one entry per `.iterationCompleted` |
| `contextBudget` | ``ContextBudget``? | Latest budget snapshot from `.budgetUpdated` |

**Methods:**

- `send(_:history:context:tokenBudget:requestContext:approvalHandler:)` cancels any active stream, resets state, and starts a new one.
- `cancel()` cancels the active stream without resetting state. It is a local cancellation API and does not guarantee a terminal `.finished` event.

When sub-agents emit nested tool events, `toolCalls` flattens them into the same collection and prefixes names using `parent > child`.

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
                        case .awaitingApproval: Text("Needs approval")
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
