# ``AgentRunKit/AgentStream``

An `@Observable` view-model wrapper over ``Agent/stream(userMessage:history:context:tokenBudget:requestContext:approvalHandler:sessionID:checkpointer:)-(String,_,_,_,_,_,_,_)``.

`finishReason` mirrors the final `.finished` event, including structural reasons such as `.maxIterationsReached(limit:)` and `.tokenBudgetExceeded(budget:used:)`. `cancel()` stops local observation and does not guarantee a terminal `.finished` event.

For checkpoint resume in SwiftUI, see <doc:CheckpointAndResume>. For late-binding event replay, see ``StreamEventBuffer``.

## Topics

### Creating a Stream

- ``init(agent:bufferCapacity:)``

### Sending Messages

- ``send(_:history:context:tokenBudget:requestContext:approvalHandler:sessionID:checkpointer:)-(String,_,_,_,_,_,_,_)``
- ``send(_:history:context:tokenBudget:requestContext:approvalHandler:sessionID:checkpointer:)-(ChatMessage,_,_,_,_,_,_,_)``
- ``cancel()``

### Resuming

- ``resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)``
- ``currentCheckpoint``
- ``iterationsReplayed``

### Observing Content

- ``content``
- ``reasoning``
- ``toolCalls``

### Stream State

- ``isStreaming``
- ``error``
- ``tokenUsage``
- ``finishReason``
- ``history``
- ``iterationUsages``
- ``contextBudget``
- ``sessionID``

### Late-Binding Replay

- ``replay(from:)``
- ``bufferedCursor``
