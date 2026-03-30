import Foundation

struct InvocationOptions {
    let tokenBudget: Int?
    let requestContext: RequestContext?
    let systemPromptOverride: String?
    let approvalHandler: ToolApprovalHandler?
}

struct IndexedToolCall {
    let index: Int
    let call: ToolCall
}

struct IndexedToolResult {
    let index: Int
    let call: ToolCall
    let result: ToolResult
}

extension Agent {
    func requiresApproval(_ call: ToolCall, allowlist: Set<String>) -> Bool {
        configuration.approvalPolicy.requiresApproval(toolName: call.name, allowlist: allowlist)
    }

    func resolveApprovals(
        _ calls: [IndexedToolCall],
        handler: @escaping ToolApprovalHandler,
        allowlist: inout Set<String>,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?
    ) async throws -> (approved: [IndexedToolCall], denied: [IndexedToolResult]) {
        var approved: [IndexedToolCall] = []
        var denied: [IndexedToolResult] = []

        for indexed in calls {
            guard let tool = tool(named: indexed.call.name) else {
                approved.append(indexed)
                continue
            }

            if allowlist.contains(indexed.call.name) {
                approved.append(indexed)
                continue
            }

            let request = ToolApprovalRequest(
                toolCallId: indexed.call.id,
                toolName: indexed.call.name,
                arguments: indexed.call.arguments,
                toolDescription: tool.description
            )
            continuation?.yield(.toolApprovalRequested(request))
            let decision = try await awaitApprovalDecision(for: request, using: handler)
            continuation?.yield(.toolApprovalResolved(toolCallId: indexed.call.id, decision: decision))

            switch decision {
            case .approve:
                approved.append(indexed)
            case .approveAlways:
                allowlist.insert(indexed.call.name)
                approved.append(indexed)
            case let .approveWithModifiedArguments(newArgs):
                let modified = ToolCall(id: indexed.call.id, name: indexed.call.name, arguments: newArgs)
                approved.append(IndexedToolCall(index: indexed.index, call: modified))
            case let .deny(reason):
                let result = ToolResult.error(reason ?? "Tool call was denied.")
                denied.append(IndexedToolResult(index: indexed.index, call: indexed.call, result: result))
            }
        }

        return (approved: approved, denied: denied)
    }
}
