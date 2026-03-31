# ``AgentRunKit/AgentStream``

An `@Observable` view-model wrapper over ``Agent/stream(userMessage:history:context:tokenBudget:requestContext:approvalHandler:)-(String,_,_,_,_,_)``.

`finishReason` mirrors the final `.finished` event, including structural reasons such as `.maxIterationsReached(limit:)` and `.tokenBudgetExceeded(budget:used:)`. `cancel()` stops local observation and does not guarantee a terminal `.finished` event.

## Topics

### Creating a Stream

- ``init(agent:)``

### Sending Messages

- ``send(_:history:context:tokenBudget:requestContext:approvalHandler:)-(String,_,_,_,_,_)``
- ``send(_:history:context:tokenBudget:requestContext:approvalHandler:)-(ChatMessage,_,_,_,_,_)``
- ``cancel()``

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
