# ``AgentRunKit/RequestContext``

Per-request metadata, provider-specific options, and request-scoped observability callbacks.

`onStreamEvent` fires only for live events emitted by the stream processor; replayed resume events bypass it. `onStreamComplete` fires at most once per underlying LLM stream call, so reactive recovery can produce multiple completions during one user-visible stream. Non-stream errors propagate through the throwing stream without a completion callback. Both callbacks run on the streaming hot path and must return synchronously without blocking I/O.

## Topics

### Observing Requests

- ``onResponse``
- ``onStreamEvent``
- ``onStreamComplete``

### Provider Options

- ``extraFields``
- ``openAIChat``
- ``anthropic``
- ``gemini``
- ``responses``
