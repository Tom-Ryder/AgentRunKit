import Foundation

protocol StreamableSubAgentTool<Context>: AnyTool {
    func executeStreaming(
        toolCallId: String,
        arguments: Data,
        context: Context,
        parentSessionID: SessionID?,
        eventHandler: @Sendable (StreamEvent) -> Void,
        approvalHandler: ToolApprovalHandler?
    ) async throws -> ToolResult
}

extension StreamableSubAgentTool {
    func executeStreaming(
        toolCallId: String,
        arguments: Data,
        context: Context,
        eventHandler: @Sendable (StreamEvent) -> Void
    ) async throws -> ToolResult {
        try await executeStreaming(
            toolCallId: toolCallId,
            arguments: arguments,
            context: context,
            parentSessionID: nil,
            eventHandler: eventHandler,
            approvalHandler: nil
        )
    }
}

protocol ApprovalAwareSubAgentTool<Context>: AnyTool {
    func executeWithApproval(
        arguments: Data,
        context: Context,
        approvalHandler: @escaping ToolApprovalHandler
    ) async throws -> ToolResult
}
