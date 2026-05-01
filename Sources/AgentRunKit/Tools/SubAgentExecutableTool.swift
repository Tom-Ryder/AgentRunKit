import Foundation

protocol SubAgentExecutableTool<Context>: AnyTool {
    func executeSubAgent(
        arguments: Data,
        context: Context,
        approvalHandler: ToolApprovalHandler?
    ) async throws -> ToolResult

    func executeSubAgentStreaming(
        arguments: Data,
        context: Context,
        parentSessionID: SessionID?,
        eventHandler: @Sendable (StreamEvent) -> Void,
        approvalHandler: ToolApprovalHandler?
    ) async throws -> ToolResult
}
