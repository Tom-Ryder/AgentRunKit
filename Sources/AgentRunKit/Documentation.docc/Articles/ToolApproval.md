# Tool Approval

Gate tool execution behind human approval using ``ToolApprovalPolicy`` and a ``ToolApprovalHandler``.

## Overview

Tool approval lets callers intercept, approve, modify, or deny tool calls before execution. The agent loop suspends at the approval point and resumes in-place when the handler returns. The stream stays open throughout.

The approval system has two parts: a **policy** on ``AgentConfiguration`` declares which tools need approval, and a **handler** passed at the call site decides each request.

## Configuring the Policy

``ToolApprovalPolicy`` is an enum with three cases:

```swift
let config = AgentConfiguration(
    approvalPolicy: .allTools          // Gate every tool call
)

let config = AgentConfiguration(
    approvalPolicy: .tools(["delete_file", "send_email"])  // Gate specific tools
)
```

The default is `.none`, which executes all tools immediately with zero overhead.

## Providing a Handler

The ``ToolApprovalHandler`` is an async closure passed to `run()` or `stream()`:

```swift
let result = try await agent.run(
    userMessage: "Delete the temp files",
    context: EmptyContext(),
    approvalHandler: { request in
        print("Tool: \(request.toolName)")
        print("Args: \(request.arguments)")
        return .approve
    }
)
```

The handler receives a ``ToolApprovalRequest`` and returns a ``ToolApprovalDecision``:

- `.approve` executes the tool as-is.
- `.approveAlways` executes and skips the handler for this tool name for the rest of the run.
- `.approveWithModifiedArguments(String)` executes with different arguments.
- `.deny(reason: String?)` skips execution and feeds the reason back to the LLM.

A precondition enforces that a handler is provided when the policy is not `.none`.

## CLI Example

```swift
let handler: ToolApprovalHandler = { request in
    print("\nApprove \(request.toolName)(\(request.arguments))? [y/n/a] ", terminator: "")
    guard let input = readLine()?.lowercased() else { return .deny(reason: "No input") }
    switch input {
    case "y": return .approve
    case "a": return .approveAlways
    case "n": return .deny(reason: "User rejected")
    default:  return .deny(reason: "Unrecognized input")
    }
}

let result = try await agent.run(
    userMessage: "Organize my downloads folder",
    context: EmptyContext(),
    approvalHandler: handler
)
```

## SwiftUI Example

Bridge the handler to a SwiftUI dialog using a continuation:

```swift
@Observable class ApprovalState {
    var pending: (request: ToolApprovalRequest,
                  continuation: CheckedContinuation<ToolApprovalDecision, Never>)?
}

let state = ApprovalState()

let handler: ToolApprovalHandler = { request in
    await withCheckedContinuation { continuation in
        Task { @MainActor in
            state.pending = (request, continuation)
        }
    }
}

// In your view:
// .sheet(item: $state.pending) { pending in
//     ApprovalDialog(request: pending.request) { decision in
//         pending.continuation.resume(returning: decision)
//         state.pending = nil
//     }
// }

stream.send("Clean up the project", context: context, approvalHandler: handler)
```

## Streaming Events

During streaming, approval emits two events per gated tool:

- ``StreamEvent/toolApprovalRequested(_:)`` before the handler is called.
- ``StreamEvent/toolApprovalResolved(toolCallId:decision:)`` after the handler returns.

These appear between ``StreamEvent/toolCallStarted(name:id:)`` and ``StreamEvent/toolCallCompleted(id:name:result:)``. ``AgentStream`` transitions the tool through `.running` to `.awaitingApproval` and back.

## Sub-Agent Propagation

When a parent agent passes an approval handler, sub-agents invoked via ``SubAgentTool`` inherit the same handler. Each sub-agent maintains its own session allowlist. Nested approval events propagate through ``StreamEvent/subAgentEvent(toolCallId:toolName:event:)`` and appear in ``AgentStream`` with composite names like `"delegate > search"`.

## Cancellation

If the parent task is cancelled while the handler is suspended, the framework immediately resumes with `CancellationError`. Callers are responsible for approval timeout policy inside their handler.
