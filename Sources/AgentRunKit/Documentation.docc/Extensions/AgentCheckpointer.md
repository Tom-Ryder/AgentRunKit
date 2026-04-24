# ``AgentRunKit/AgentCheckpointer``

Persistence backend for ``AgentCheckpoint`` snapshots.

Conform to write a custom backend (database, remote storage). The two built-in conformances are ``InMemoryCheckpointer`` and ``FileCheckpointer``. See <doc:CheckpointAndResume>.

## Topics

### Operations

- ``save(_:)``
- ``load(_:)``
- ``list(session:)``

### Built-In Backends

- ``InMemoryCheckpointer``
- ``FileCheckpointer``

### Errors

- ``AgentCheckpointError``
