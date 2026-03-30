import Foundation

/// Determines which tools require human approval before execution.
public enum ToolApprovalPolicy: Sendable, Equatable {
    case none
    case allTools
    case tools(Set<String>)
}

extension ToolApprovalPolicy {
    func requiresApproval(toolName: String, allowlist: Set<String>) -> Bool {
        if allowlist.contains(toolName) { return false }
        switch self {
        case .none: return false
        case .allTools: return true
        case let .tools(names): return names.contains(toolName)
        }
    }
}

/// Describes a pending tool call that requires approval before execution.
public struct ToolApprovalRequest: Sendable, Equatable {
    public let toolCallId: String
    public let toolName: String
    public let arguments: String
    public let toolDescription: String
}

/// Captures the caller's decision for a pending tool approval request.
public enum ToolApprovalDecision: Sendable, Equatable {
    case approve
    case approveAlways
    case approveWithModifiedArguments(String)
    case deny(reason: String?)
}

/// Asynchronously resolves a tool approval request.
///
/// Callers remain responsible for approval timeout policy, while task cancellation aborts waiting immediately.
public typealias ToolApprovalHandler = @Sendable (ToolApprovalRequest) async -> ToolApprovalDecision

private actor ApprovalDecisionWaiter {
    private var continuation: CheckedContinuation<ToolApprovalDecision, Error>?
    private var result: Result<ToolApprovalDecision, Error>?

    func store(_ continuation: CheckedContinuation<ToolApprovalDecision, Error>) {
        if let result {
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
        }
    }

    func resume(with result: Result<ToolApprovalDecision, Error>) {
        guard self.result == nil else { return }
        self.result = result
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

func awaitApprovalDecision(
    for request: ToolApprovalRequest,
    using handler: @escaping ToolApprovalHandler
) async throws -> ToolApprovalDecision {
    let waiter = ApprovalDecisionWaiter()
    let handlerTask = Task {
        let decision = await handler(request)
        await waiter.resume(with: .success(decision))
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolApprovalDecision, Error>) in
            Task {
                await waiter.store(continuation)
            }
        }
    } onCancel: {
        handlerTask.cancel()
        Task {
            await waiter.resume(with: .failure(CancellationError()))
        }
    }
}
