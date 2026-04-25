import Foundation

struct InvocationOptions {
    let tokenBudget: Int?
    let requestContext: RequestContext?
    let systemPromptOverride: String?
    let approvalHandler: ToolApprovalHandler?
    let sessionID: SessionID?
    let runID: RunID?
    let checkpointer: (any AgentCheckpointer)?
    let eventFactory: StreamEventFactory

    init(
        tokenBudget: Int?,
        requestContext: RequestContext?,
        systemPromptOverride: String?,
        approvalHandler: ToolApprovalHandler?,
        sessionID: SessionID? = nil,
        runID: RunID? = nil,
        checkpointer: (any AgentCheckpointer)? = nil
    ) {
        self.tokenBudget = tokenBudget
        self.requestContext = requestContext
        self.systemPromptOverride = systemPromptOverride
        self.approvalHandler = approvalHandler
        self.sessionID = sessionID
        self.runID = runID
        self.checkpointer = checkpointer
        eventFactory = StreamEventFactory(sessionID: sessionID, runID: runID, origin: .live)
    }
}
