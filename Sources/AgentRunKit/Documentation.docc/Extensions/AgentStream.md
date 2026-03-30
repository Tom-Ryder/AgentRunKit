# ``AgentRunKit/AgentStream``

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
