# ``AgentRunKit/Agent``

## Topics

### Creating an Agent

- ``init(client:tools:configuration:)``

### Running

- ``run(userMessage:history:context:tokenBudget:requestContext:)-(String,_,_,_,_)``
- ``run(userMessage:history:context:tokenBudget:requestContext:)-(ChatMessage,_,_,_,_)``

### Streaming

- ``stream(userMessage:history:context:tokenBudget:requestContext:)-(String,_,_,_,_)``
- ``stream(userMessage:history:context:tokenBudget:requestContext:)-(ChatMessage,_,_,_,_)``
