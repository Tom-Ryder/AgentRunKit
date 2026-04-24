# ``AgentRunKit/InMemoryCheckpointer``

In-process checkpointer backed by an actor-protected dictionary.

Use for previews, tests, and sessions bounded by a single process lifetime. Storage is lost when the actor goes out of scope. For persistence across process restart, use ``FileCheckpointer``. See <doc:CheckpointAndResume>.

## Topics

### Initialization

- ``init()``

### Operations

- ``save(_:)``
- ``load(_:)``
- ``list(session:)``
