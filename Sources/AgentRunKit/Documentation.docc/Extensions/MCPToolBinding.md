# ``AgentRunKit/MCPToolBinding``

Identifies an MCP tool that participated in a checkpoint's history.

Recorded automatically by the agent loop into ``AgentCheckpoint/mcpToolBindings``. ``Agent/resume(from:checkpointer:context:tokenBudget:requestContext:approvalHandler:)`` validates that every recorded binding has a live counterpart on the resuming agent and throws ``AgentCheckpointError/mcpBindingMismatch(_:)`` if any are missing. See <doc:MCPIntegration> and <doc:CheckpointAndResume>.

## Topics

### Identity

- ``serverName``
- ``toolName``

### Initialization

- ``init(serverName:toolName:)``
