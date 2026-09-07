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
        switch usage.coverage {
        case .complete: print("\nTokens: \(usage.total)")
        case .partial: print("\nReported subtotal: \(usage.total) tokens")
        case .unavailable: print("\nUsage unavailable")
        }
        if let reason {
            print("Reason: \(reason)")
        }
    default:
        break
    }
}
```

Expected terminal states such as max-iterations and token-budget exhaustion arrive as `.finished` events with structural ``FinishReason`` payloads. Only genuine runtime failures throw. Cancelling the consuming task cancels the underlying LLM request and does not guarantee a terminal `.finished` event.

Use ``RequestContext`` stream callbacks when telemetry needs the live events emitted by the LLM stream processor or the terminal state of each underlying LLM stream call:

```swift
let requestContext = RequestContext(
    onStreamEvent: { event in
        print(event.kind)
    },
    onStreamComplete: { completion in
        print(completion)
    }
)
let stream = agent.stream(
    userMessage: "Summarize this paper.",
    context: ctx,
    requestContext: requestContext
)
```

Stream callbacks are scoped per LLM stream call, not per user-visible `Agent.stream(...)` invocation. Reactive recovery can emit a failed completion followed by a successful completion for the retry. Replayed events from `Agent.resume(...)` do not fire callbacks. Non-stream errors propagate through the throwing stream without a completion callback, and callbacks must return synchronously without blocking I/O.

## StreamEvent Envelope

``StreamEvent`` is an envelope struct. The semantic event is carried by ``StreamEvent/kind`` as a ``StreamEvent/Kind`` value.

Every event includes:

| Property | Description |
|---|---|
| ``StreamEvent/id`` | Stable event identity for transcript rendering and correlation |
| ``StreamEvent/timestamp`` | Emission time in UTC |
| ``StreamEvent/sessionID`` | Session identity, populated when a stream is started with `sessionID:` |
| ``StreamEvent/runID`` | Run identity, freshly assigned on each `stream()` or `resume(...)` |
| ``StreamEvent/origin`` | ``EventOrigin/live`` or ``EventOrigin/replayed(from:)`` (set on resume) |
| ``StreamEvent/kind`` | The semantic payload |

Pass `sessionID:` to ``Agent/stream(userMessage:history:context:tokenBudget:requestContext:approvalHandler:sessionID:checkpointer:)-(String,_,_,_,_,_,_,_)`` to thread an explicit session through events; otherwise a fresh ``SessionID`` is minted per stream. ``Chat`` continues to leave identity envelope fields unset on its own events, while nested child events inside ``StreamEvent/Kind/subAgentEvent(toolCallId:toolName:event:)`` carry the child's own minted session identity.

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
| ``StreamEvent/Kind/finished(tokenUsage:content:reason:history:)`` | ``TokenUsageTotals``, content, reason, history | Agent or Chat completed with aggregate measurement coverage |
| ``StreamEvent/Kind/iterationCompleted(usage:iteration:history:)`` | ``TokenUsage``?, iteration number, post-append message snapshot | A provider turn completed, including turns without usage |
| ``StreamEvent/Kind/compacted(totalTokens:windowSize:)`` | `totalTokens`, `windowSize` | Context was compacted to fit the window |
| ``StreamEvent/Kind/budgetUpdated(budget:)`` | ``ContextBudget`` | Latest budget snapshot after a provider response |
| ``StreamEvent/Kind/budgetAdvisory(budget:)`` | ``ContextBudget`` | Soft threshold was crossed |

## Completion and Durability

`.toolCallCompleted` reports that a tool finished executing. Top-level `.finished` reports that the agent run itself succeeded. The two are not interchangeable, and the gap between them matters when the run has a completion tool (see <doc:AgentAndChat#Custom-Completion-Tools>) and a checkpointer.

For a successful completion the order is fixed: `.toolCallStarted`, approval and execution with any nested sub-agent events, the exact `.toolCallCompleted`, the terminal checkpoint save, then top-level `.finished`, then the stream closes. `.iterationCompleted` may arrive before execution, because it reports provider-turn completion rather than tool completion.

That ordering is the durability contract. A consumer that returns as soon as it sees the completion tool's `.toolCallCompleted` terminates the stream and cancels the producer, potentially before the checkpoint is written. Wait for top-level `.finished`. If the save fails, the error propagates, no `.finished` is emitted, and no terminal state is published — the tool's own side effects cannot be rolled back, which is why completion tools must be idempotent.

With no checkpointer configured, `.finished` is still authoritative for logical success but carries no durability claim at all.

Raw-stream consumers can recover the saved checkpoint after `.finished` with ``FileCheckpointer/list(session:)``; because the save precedes the event, the terminal checkpoint is already present. ``AgentStream`` consumers do not need that call: `currentCheckpoint` tracks live saves, so it holds the terminal checkpoint's ID by the time `.finished` arrives.

## Canonical Transcript JSON

Use ``StreamEventJSONCodec`` when you need stable transcript export or import:

```swift
let data = try StreamEventJSONCodec.encode(event)
let restored = try StreamEventJSONCodec.decode(data)
```

This canonical codec uses the framework's fixed JSON settings for event transcripts. Plain `Codable` conformance remains available for ordinary Swift use, but transcript persistence should go through ``StreamEventJSONCodec``.

Finished events encode token totals and coverage as described in <doc:TokenAccounting>. Iteration events omit `usage` when it is unavailable; absent or null usage decodes as `nil`. If `history` is absent, it decodes as an empty array; present null or malformed history throws a decoding error.

## AgentStream for SwiftUI

``AgentStream`` is an `@Observable`, `@MainActor` class that consumes a stream and exposes collected state. Create one from an ``Agent``:

```swift
@State private var stream = AgentStream(agent: agent)
```

**Properties:**

| Property | Type | Description |
|---|---|---|
| `content` | `String` | Accumulated text from `.delta` events, falling back to the final content when the run produced no deltas |
| `reasoning` | `String` | Accumulated reasoning from `.reasoningDelta` events |
| `isStreaming` | `Bool` | True while a stream is active |
| `error` | `(any Error & Sendable)?` | Set if the stream throws |
| `tokenUsage` | ``TokenUsageTotals``? | Aggregate usage and coverage from `.finished` or checkpoint preload |
| `finishReason` | `FinishReason?` | Reason from `.finished`, including structural max-iterations or token-budget limits |
| `terminalContent` | `String?` | Content of the top-level `.finished` event; `nil` until the run completes and for structural terminations |
| `history` | `[ChatMessage]` | Full conversation history from `.finished` |
| `toolCalls` | [``ToolCallInfo``] | Top-level and nested tool calls with live state (`.running`, `.awaitingApproval`, `.completed`, `.failed`) |
| `iterationUsages` | [``TokenUsage``?] | One sample per `.iterationCompleted`, retaining `nil` for unavailable usage |
| `contextBudget` | ``ContextBudget``? | Latest budget snapshot from `.budgetUpdated` |
| `sessionID` | ``SessionID``? | Session identity threaded through emitted events |
| `currentCheckpoint` | ``CheckpointID``? | Most recent checkpoint saved by the live run, preloaded on resume |
| `iterationsReplayed` | `Int` | Count of replayed iteration snapshots, including snapshots without usage |

**Methods:**

- `send(_:history:context:tokenBudget:requestContext:approvalHandler:sessionID:checkpointer:)` cancels any active stream, resets state, and starts a new one. Pass `sessionID:` and `checkpointer:` to persist iteration state.
- `resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)` synchronously preloads observable state from the loaded checkpoint, then starts the live continuation. See <doc:CheckpointAndResume>.
- `cancel()` cancels the active stream without resetting state. It is a local cancellation API and does not guarantee a terminal `.finished` event.

### Final Content

`content` and `terminalContent` answer different questions. `content` is what the user watched arrive: the accumulated `.delta` text, falling back to the final content only when the run streamed no deltas at all. `terminalContent` is the run's result, assigned from the top-level `.finished` event whether it came from the built-in `finish` tool, a completion tool, or a content-only client. Structural terminations carry no content, so `terminalContent` stays `nil` after max iterations or token-budget exhaustion — which distinguishes them from a completion whose result happened to be empty.

### Root State and Nested Agents

Aggregate state describes the parent run only. `tokenUsage`, `finishReason`, `terminalContent`, `history`, the `content` fallback, `iterationUsages`, `iterationsReplayed`, and `contextBudget` are written by root `.finished`, `.iterationCompleted`, and `.budgetUpdated` events; the same events nested inside ``StreamEvent/Kind/subAgentEvent(toolCallId:toolName:event:)`` never touch them. Nested events remain fully observable — they still arrive on the stream, and `toolCalls` still flattens nested tool activity — but a sub-agent finishing is not the parent finishing.

### Late-Binding Replay

Construct ``AgentStream`` with a `bufferCapacity:` to capture every emitted event in a ``StreamEventBuffer``. Late observers reattach via ``AgentStream/replay(from:)``, which streams every buffered event from the given monotonic cursor and then errors with ``BufferReplayError`` if buffering is disabled. The buffer is per-send-isolated: a new `send` or `resume` clears the buffer to keep cursors comparable within one logical run.

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

Every completed Agent provider turn yields `.iterationCompleted` with that iteration's optional ``TokenUsage``. Missing usage preserves the iteration number and history; it never becomes a zero measurement. Foundation Models, which does not report token usage, therefore emits an iteration event with `nil` usage too. The `.finished` event carries ``TokenUsageTotals``, including measurement coverage and any returned summarization responses. See <doc:TokenAccounting>.

``AgentStream`` collects samples in event order, retaining missing positions in `iterationUsages`. Resume contributes the saved iteration snapshot before live samples; it does not reconstruct earlier samples. Use the event's `iteration` value when the original iteration number matters.

```swift
for (index, usage) in stream.iterationUsages.enumerated() {
    if let usage {
        print("Sample \(index + 1): \(usage.input)in / \(usage.output)out")
    } else {
        print("Sample \(index + 1): usage unavailable")
    }
}
```

## See Also

- <doc:AgentAndChat>
- <doc:SubAgents>
- <doc:CheckpointAndResume>
- ``StreamEvent``
- ``EventOrigin``
- ``AgentStream``
- ``StreamEventBuffer``
- ``ToolCallInfo``
- ``TokenUsage``
