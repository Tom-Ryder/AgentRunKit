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
public struct ToolApprovalRequest: Sendable, Equatable, Codable {
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

extension ToolApprovalDecision: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, arguments, reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "approve": self = .approve
        case "approveAlways": self = .approveAlways
        case "approveWithModifiedArguments":
            self = try .approveWithModifiedArguments(container.decode(String.self, forKey: .arguments))
        case "deny":
            self = try .deny(reason: container.decodeIfPresent(String.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown ToolApprovalDecision type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .approve:
            try container.encode("approve", forKey: .type)
        case .approveAlways:
            try container.encode("approveAlways", forKey: .type)
        case let .approveWithModifiedArguments(args):
            try container.encode("approveWithModifiedArguments", forKey: .type)
            try container.encode(args, forKey: .arguments)
        case let .deny(reason):
            try container.encode("deny", forKey: .type)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }
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
