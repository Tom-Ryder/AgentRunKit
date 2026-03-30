import Foundation
import Observation

public struct ToolCallInfo: Sendable, Identifiable {
    public let id: String
    public let name: String
    public var state: ToolCallState

    public enum ToolCallState: Sendable {
        case running
        case awaitingApproval
        case completed(String)
        case failed(String)
    }
}

/// An `@Observable` wrapper around `Agent.stream()` for SwiftUI.
///
/// For a guide, see <doc:StreamingAndSwiftUI>.
@Observable
@MainActor
public final class AgentStream<C: ToolContext> {
    public private(set) var content: String = ""
    public private(set) var reasoning: String = ""
    public private(set) var isStreaming: Bool = false
    public private(set) var error: (any Error & Sendable)?
    public private(set) var tokenUsage: TokenUsage?
    public private(set) var finishReason: FinishReason?
    public private(set) var history: [ChatMessage] = []
    public private(set) var toolCalls: [ToolCallInfo] = []
    public private(set) var iterationUsages: [TokenUsage] = []
    public private(set) var contextBudget: ContextBudget?

    private let agent: Agent<C>
    private var activeTask: Task<Void, Never>?

    public init(agent: Agent<C>) {
        self.agent = agent
    }

    public func send(
        _ message: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) {
        send(
            .user(message), history: history, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext,
            approvalHandler: approvalHandler
        )
    }

    public func send(
        _ message: ChatMessage,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) {
        cancel()
        reset()
        isStreaming = true

        activeTask = Task { [agent] in
            do {
                let stream = agent.stream(
                    userMessage: message,
                    history: history,
                    context: context,
                    tokenBudget: tokenBudget,
                    requestContext: requestContext,
                    approvalHandler: approvalHandler
                )
                for try await event in stream {
                    self.handle(event)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error
            }
            self.isStreaming = false
        }
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isStreaming = false
    }

    private func reset() {
        content = ""
        reasoning = ""
        error = nil
        tokenUsage = nil
        finishReason = nil
        history = []
        toolCalls = []
        iterationUsages = []
        contextBudget = nil
    }

    private func handle(_ event: StreamEvent) {
        handle(event, toolCallIdPath: [], toolNamePath: [])
    }

    private func handle(_ event: StreamEvent, toolCallIdPath: [String], toolNamePath: [String]) {
        switch event {
        case let .delta(text):
            content += text
        case let .reasoningDelta(text):
            reasoning += text
        case let .toolCallStarted(name, id):
            toolCalls.append(ToolCallInfo(
                id: compositeToolCallId(localId: id, path: toolCallIdPath),
                name: compositeToolName(localName: name, path: toolNamePath),
                state: .running
            ))
        case let .toolCallCompleted(id, _, result):
            let compositeId = compositeToolCallId(localId: id, path: toolCallIdPath)
            if let index = toolCalls.firstIndex(where: { $0.id == compositeId }) {
                toolCalls[index].state = result.isError
                    ? .failed(result.content)
                    : .completed(result.content)
            }
        case let .toolApprovalRequested(request):
            handleApprovalRequested(request, toolCallIdPath: toolCallIdPath, toolNamePath: toolNamePath)
        case let .toolApprovalResolved(toolCallId, decision):
            handleApprovalResolved(
                toolCallId: toolCallId,
                decision: decision,
                toolCallIdPath: toolCallIdPath
            )
        case .audioData, .audioTranscript, .audioFinished,
             .subAgentStarted, .subAgentCompleted,
             .compacted, .budgetAdvisory:
            break
        case let .subAgentEvent(toolCallId, toolName, nestedEvent):
            handle(
                nestedEvent,
                toolCallIdPath: toolCallIdPath + [toolCallId],
                toolNamePath: toolNamePath + [toolName]
            )
        case let .finished(usage, finishContent, reason, hist):
            tokenUsage = usage
            finishReason = reason
            history = hist
            if let finishContent, content.isEmpty {
                content = finishContent
            }
        case let .iterationCompleted(usage, _):
            iterationUsages.append(usage)
        case let .budgetUpdated(budget):
            contextBudget = budget
        }
    }

    private func handleApprovalRequested(
        _ request: ToolApprovalRequest,
        toolCallIdPath: [String],
        toolNamePath: [String]
    ) {
        let compositeId = compositeToolCallId(localId: request.toolCallId, path: toolCallIdPath)
        let compositeName = compositeToolName(localName: request.toolName, path: toolNamePath)
        if let index = toolCalls.firstIndex(where: { $0.id == compositeId }) {
            toolCalls[index].state = .awaitingApproval
        } else {
            toolCalls.append(ToolCallInfo(
                id: compositeId, name: compositeName, state: .awaitingApproval
            ))
        }
    }

    private func handleApprovalResolved(
        toolCallId: String,
        decision: ToolApprovalDecision,
        toolCallIdPath: [String]
    ) {
        let compositeId = compositeToolCallId(localId: toolCallId, path: toolCallIdPath)
        guard let index = toolCalls.firstIndex(where: { $0.id == compositeId }) else { return }
        switch decision {
        case .approve, .approveAlways, .approveWithModifiedArguments:
            toolCalls[index].state = .running
        case let .deny(reason):
            toolCalls[index].state = .failed(reason ?? "Denied")
        }
    }

    private func compositeToolCallId(localId: String, path: [String]) -> String {
        guard !path.isEmpty else { return localId }
        return (path + [localId]).joined(separator: "/")
    }

    private func compositeToolName(localName: String, path: [String]) -> String {
        guard !path.isEmpty else { return localName }
        return (path + [localName]).joined(separator: " > ")
    }
}
