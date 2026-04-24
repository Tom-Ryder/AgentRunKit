# ``AgentRunKit/ContextBudgetCheckpointState``

Serializable snapshot of a context budget phase, embedded in ``AgentCheckpoint/contextBudgetState``.

Captures the budget config, the model's window size, the most recent ``ContextBudget`` snapshot, and whether the soft-threshold advisory has already fired this run. Restored by ``Agent/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` so resumed runs do not re-emit a soft advisory the original run already delivered. See <doc:ContextManagement> and <doc:CheckpointAndResume>.

## Topics

### State

- ``config``
- ``windowSize``
- ``lastBudget``
- ``softAdvisoryArmed``

### Initialization

- ``init(config:windowSize:lastBudget:softAdvisoryArmed:)``
