# ``AgentRunKit/FileCheckpointer``

JSON-on-disk checkpointer for cross-process resume.

Stores one file per checkpoint at `<directory>/checkpoints/<uuid>.json`. The base directory is created on first save. ``list(session:)`` skips files it cannot read or decode and returns checkpoints sorted by iteration then timestamp; ``load(_:)`` throws ``AgentCheckpointError/fileSystem(_:)`` for the requested file when it is corrupt. The backend is single-writer oriented; coordinate access from multiple processes externally or use a database-backed custom ``AgentCheckpointer``. See <doc:CheckpointAndResume>.

## Topics

### Initialization

- ``init(directory:fileManager:)``

### Operations

- ``save(_:)``
- ``load(_:)``
- ``list(session:)``
