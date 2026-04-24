# ``AgentRunKit/AgentCheckpoint``

Snapshot of agent loop state captured at the end of an iteration.

The snapshot is what ``Agent/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` reads to reconstruct a run. See <doc:CheckpointAndResume> for the full lifecycle.

## Topics

### Identity

- ``checkpointID``
- ``sessionID``
- ``runID``
- ``timestamp``

### Loop State

- ``messages``
- ``iteration``
- ``tokenUsage``
- ``iterationUsage``

### Resume Inputs

- ``contextBudgetState``
- ``historyWasRewrittenLocally``
- ``sessionAllowlist``
- ``mcpToolBindings``

### Initialization

- ``init(messages:iteration:tokenUsage:iterationUsage:contextBudgetState:historyWasRewrittenLocally:sessionAllowlist:sessionID:runID:checkpointID:timestamp:mcpToolBindings:)``
