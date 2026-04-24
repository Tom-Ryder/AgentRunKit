# ``AgentRunKit/AgentCheckpointError``

Errors thrown by ``AgentCheckpointer`` backends and ``Agent/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)``.

See <doc:CheckpointAndResume> for the resume contract that surfaces these.

## Topics

### Cases

- ``notFound(_:)``
- ``fileSystem(_:)``
- ``mcpBindingMismatch(_:)``

### LocalizedError

- ``errorDescription``
