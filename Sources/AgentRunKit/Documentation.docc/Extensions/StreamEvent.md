# ``AgentRunKit/StreamEvent``

## Topics

### Content Events

- ``delta(_:)``
- ``reasoningDelta(_:)``

### Tool Events

- ``toolCallStarted(name:id:)``
- ``toolCallCompleted(id:name:result:)``

### Approval Events

- ``toolApprovalRequested(_:)``
- ``toolApprovalResolved(toolCallId:decision:)``

### Audio Events

- ``audioData(_:)``
- ``audioTranscript(_:)``
- ``audioFinished(id:expiresAt:data:)``

### Sub-Agent Events

- ``subAgentStarted(toolCallId:toolName:)``
- ``subAgentEvent(toolCallId:toolName:event:)``
- ``subAgentCompleted(toolCallId:toolName:result:)``

### Lifecycle Events

- ``finished(tokenUsage:content:reason:history:)``
- ``iterationCompleted(usage:iteration:)``
- ``compacted(totalTokens:windowSize:)``
- ``budgetUpdated(budget:)``
- ``budgetAdvisory(budget:)``
