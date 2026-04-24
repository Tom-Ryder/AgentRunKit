# Checkpoint and Resume

Persist iteration state mid-run, then resume from any saved checkpoint into a fresh streaming continuation.

## Overview

A checkpointer captures the agent's full loop state at the end of every iteration: messages, accumulated token usage, per-iteration usage, context budget phase, session and run identity, the local-rewrite flag, the session approval allowlist, and any participating MCP tool bindings. ``Agent/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` loads a saved checkpoint, replays its history into the consuming stream as one synthetic event, then continues live from the next iteration.

This unblocks long-running sessions that need to survive process restarts, UI re-renders, or planned suspension. Checkpoints are written automatically by ``Agent/stream(userMessage:history:context:tokenBudget:requestContext:approvalHandler:sessionID:checkpointer:)-(String,_,_,_,_,_,_,_)`` when both a `sessionID` and a `checkpointer` are passed.

## What a Checkpoint Captures

``AgentCheckpoint`` is a `Codable` snapshot. It is written at the end of each iteration after tools execute and before the next request is built.

| Field | Description |
|---|---|
| `messages` | Full conversation including system prompt, user, assistant, and tool messages |
| `iteration` | One-based iteration number that produced this snapshot |
| `tokenUsage` | Cumulative input/output usage across all iterations to date |
| `iterationUsage` | Token usage for this iteration alone, when the provider reported it |
| `contextBudgetState` | ``ContextBudgetCheckpointState`` capturing config, window size, last budget snapshot, and the soft-advisory armed flag |
| `historyWasRewrittenLocally` | Whether the agent rewrote history (compaction, pruning) before this iteration |
| `sessionAllowlist` | Tool names the user accepted with `.approveAlways` during this session |
| `sessionID` | Logical session that owns the run |
| `runID` | Run that produced this checkpoint |
| `checkpointID` | Stable identity for the snapshot |
| `timestamp` | UTC time the snapshot was taken |
| `mcpToolBindings` | ``MCPToolBinding`` set: which MCP tools participated in this checkpoint's history |

## Backends

``AgentCheckpointer`` is a three-method protocol. Two backends ship with the framework.

| Backend | Use When |
|---|---|
| ``InMemoryCheckpointer`` | The session is bounded by a single process lifetime: previews, tests, transient UI |
| ``FileCheckpointer`` | The session must survive process restart: production apps, server workers, recovery flows |

``FileCheckpointer`` stores one JSON file per checkpoint under `<directory>/checkpoints/<uuid>.json`. ``FileCheckpointer/list(session:)`` skips files it cannot read or decode, so unrelated debris in the directory does not break enumeration. ``FileCheckpointer/load(_:)`` throws ``AgentCheckpointError/fileSystem(_:)`` on the requested file if it is corrupt.

Custom backends conform to ``AgentCheckpointer`` directly; database-backed and remote-storage implementations are out of scope for the built-in backends.

## Enabling Checkpointing on a Stream

Pass `sessionID:` and `checkpointer:` to either entry point.

```swift
let session = SessionID()
let checkpointer = InMemoryCheckpointer()

let stream = agent.stream(
    userMessage: "Plan and execute the migration.",
    context: ctx,
    sessionID: session,
    checkpointer: checkpointer
)
for try await event in stream {
    handle(event)
}

let savedIDs = try await checkpointer.list(session: session)
```

If either argument is omitted, no checkpoint is written. The `stream()` overloads continue to default both to `nil`, so existing call sites are unaffected.

## Resuming a Run

``Agent/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` loads the named checkpoint, replays its history as one synthetic ``StreamEvent/Kind/iterationCompleted(usage:iteration:history:)`` event tagged with ``EventOrigin/replayed(from:)``, then continues from `iteration + 1`.

```swift
let stream = try await agent.resume(
    from: checkpointID,
    checkpointer: checkpointer,
    context: ctx
)
for try await event in stream {
    if case .replayed(let id) = event.origin {
        applySnapshot(id)
        continue
    }
    handle(event)
}
```

The resumed run gets a fresh ``RunID`` under the same ``SessionID``. Callers can distinguish replayed events from the live continuation by inspecting ``StreamEvent/origin``.

### Preflight Termination

If the saved checkpoint already exceeds the new `tokenBudget`, the stream replays and finishes with ``FinishReason/tokenBudgetExceeded(budget:used:)`` without making any LLM call. If `iteration >= maxIterations`, it replays and finishes with ``FinishReason/maxIterationsReached(limit:)``.

### Cursor-State Providers

Providers with conversation cursor state (the OpenAI Responses API's `previous_response_id`) cannot reuse a stale cursor after resume because the resumed run is a different run. The first live request after resume forces full history (`.forceFullRequest`) so cursor-state providers reconstruct the conversation from messages rather than from a vanished cursor.

### MCP Binding Validation

Before replay begins, ``Agent/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` checks that every ``MCPToolBinding`` recorded in the checkpoint has a live counterpart on the resuming agent. If any are missing, resume throws ``AgentCheckpointError/mcpBindingMismatch(_:)`` with the missing bindings before any event is yielded. This catches deployment skew where the agent that resumes is configured against fewer or different MCP servers than the agent that saved.

See <doc:MCPIntegration> for how MCP tools are discovered.

## AgentStream Resume

``AgentStream/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` is the SwiftUI-side entry point. It cancels any in-flight prior task before any await runs, loads the checkpoint exactly once, then synchronously preloads observable state before yielding control back to the caller.

```swift
@State private var stream = AgentStream(agent: agent, bufferCapacity: 256)

try await stream.resume(
    from: checkpointID,
    checkpointer: checkpointer,
    context: ctx
)
```

When `resume` returns, these properties are already populated from the checkpoint:

| Property | Source |
|---|---|
| ``AgentStream/sessionID`` | `target.sessionID` |
| ``AgentStream/history`` | `target.messages` |
| ``AgentStream/tokenUsage`` | `target.tokenUsage` |
| ``AgentStream/currentCheckpoint`` | `target.checkpointID` |

The live continuation runs in a background task; ``AgentStream/iterationsReplayed`` increments once the synthetic replay event is observed, then the live iteration cycle proceeds normally. ``AgentStream/iterationsReplayed`` only counts replayed iterations, so callers can distinguish a fresh send from a resume.

See <doc:StreamingAndSwiftUI> for the full SwiftUI contract.

## Cancellation Safety

``AgentStream/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` calls ``AgentStream/cancel()`` and resets observable state before any await. A prior in-flight task cannot continue mutating observers while the new checkpoint loads. The same generation-token discipline that protects ``AgentStream/send(_:history:context:tokenBudget:requestContext:approvalHandler:sessionID:checkpointer:)-(String,_,_,_,_,_,_,_)`` against late-arriving stale events applies to resume.

## Cross-Process Resume

``FileCheckpointer`` is safe to use from a fresh process. The directory layout is stable; reopening the same directory and calling ``FileCheckpointer/list(session:)`` returns checkpoints written by an earlier process.

```swift
// Process A
let writer = FileCheckpointer(directory: stateDirectory)
for try await _ in agent.stream(
    userMessage: "Long task...",
    context: ctx, sessionID: session, checkpointer: writer
) {}

// Process B (later)
let reader = FileCheckpointer(directory: stateDirectory)
let ids = try await reader.list(session: session)
guard let last = ids.last else { return }
let stream = try await agent.resume(
    from: last, checkpointer: reader, context: ctx
)
```

The file backend is single-writer oriented. Multi-process coordination over the same directory is the caller's responsibility; for concurrent writers, use a database-backed custom ``AgentCheckpointer``.

## Errors

``AgentCheckpointError`` covers the three failure modes that resume can surface:

| Case | Meaning |
|---|---|
| ``AgentCheckpointError/notFound(_:)`` | The named ``CheckpointID`` is not present in the backend |
| ``AgentCheckpointError/fileSystem(_:)`` | A file backend operation failed (read, write, decode for the requested ID) |
| ``AgentCheckpointError/mcpBindingMismatch(_:)`` | Resume cannot continue because one or more recorded MCP bindings have no live counterpart |

## See Also

- <doc:StreamingAndSwiftUI>
- <doc:MCPIntegration>
- ``AgentCheckpoint``
- ``AgentCheckpointer``
- ``InMemoryCheckpointer``
- ``FileCheckpointer``
- ``MCPToolBinding``
- ``AgentCheckpointError``
- ``ContextBudgetCheckpointState``
- ``EventOrigin``
- ``CheckpointID``
- ``SessionID``
- ``RunID``
