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
    public private(set) var sessionID: SessionID?
    public private(set) var iterationsReplayed: Int = 0
    public private(set) var currentCheckpoint: CheckpointID?

    private let agent: Agent<C>
    let buffer: StreamEventBuffer?
    private var activeTask: Task<Void, Never>?
    var sendGeneration: UInt64 = 0

    public init(agent: Agent<C>, bufferCapacity: Int? = nil) {
        self.agent = agent
        buffer = bufferCapacity.map { StreamEventBuffer(capacity: $0) }
    }

    public func send(
        _ message: String,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil,
        sessionID: SessionID? = nil,
        checkpointer: (any AgentCheckpointer)? = nil
    ) {
        send(
            .user(message), history: history, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext,
            approvalHandler: approvalHandler, sessionID: sessionID,
            checkpointer: checkpointer
        )
    }

    public func send(
        _ message: ChatMessage,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil,
        sessionID: SessionID? = nil,
        checkpointer: (any AgentCheckpointer)? = nil
    ) {
        cancel()
        reset()
        sendGeneration &+= 1
        let generation = sendGeneration
        isStreaming = true
        self.sessionID = sessionID
        let stream = agent.stream(
            userMessage: message, history: history, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext,
            approvalHandler: approvalHandler, sessionID: sessionID,
            checkpointer: checkpointer
        )
        activeTask = Task { await self.runStreamTask(generation: generation, stream: stream) }
    }

    private func runStreamTask(
        generation: UInt64,
        stream: AsyncThrowingStream<StreamEvent, Error>
    ) async {
        if let buffer { await buffer.clear() }
        do {
            for try await event in stream {
                guard generation == sendGeneration else { continue }
                if let buffer { await buffer.record(event) }
                guard generation == sendGeneration else { continue }
                handle(event)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == sendGeneration else { return }
            self.error = error
        }
        guard generation == sendGeneration else { return }
        isStreaming = false
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        sendGeneration &+= 1
        isStreaming = false
    }

    /// Synchronously preloads observable state from the checkpoint before the live continuation begins.
    public func resume(
        from checkpointID: CheckpointID,
        checkpointer: any AgentCheckpointer,
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws {
        cancel()
        reset()
        let target = try await checkpointer.load(checkpointID)
        let resumedStream = try await agent.resume(
            target: target, checkpointer: checkpointer, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext,
            approvalHandler: approvalHandler
        )
        sendGeneration &+= 1
        let generation = sendGeneration
        isStreaming = true
        sessionID = target.sessionID
        history = target.messages
        tokenUsage = target.tokenUsage
        currentCheckpoint = target.checkpointID
        activeTask = Task { await self.runStreamTask(generation: generation, stream: resumedStream) }
    }

    public func replay(from cursor: UInt64) -> AsyncThrowingStream<StreamEvent, Error> {
        guard let buffer else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: BufferReplayError.bufferDisabled)
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in await buffer.replay(from: cursor) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public var bufferedCursor: UInt64? {
        get async { await buffer?.cursor }
    }
}

extension AgentStream {
    func handle(_ event: StreamEvent) {
        handle(event, toolCallIdPath: [], toolNamePath: [])
    }

    func handle(_ event: StreamEvent, toolCallIdPath: [String], toolNamePath: [String]) {
        observeEnvelope(event)
        switch event.kind {
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
            updateToolCallState(id: id, path: toolCallIdPath, result: result)
        case let .toolApprovalRequested(request):
            handleApprovalRequested(request, toolCallIdPath: toolCallIdPath, toolNamePath: toolNamePath)
        case let .toolApprovalResolved(toolCallId, decision):
            handleApprovalResolved(toolCallId: toolCallId, decision: decision, toolCallIdPath: toolCallIdPath)
        case .audioData, .audioTranscript, .audioFinished,
             .subAgentStarted, .subAgentCompleted,
             .compacted, .budgetAdvisory:
            break
        case let .subAgentEvent(toolCallId, toolName, nestedEvent):
            handle(
                nestedEvent.with(origin: event.origin),
                toolCallIdPath: toolCallIdPath + [toolCallId],
                toolNamePath: toolNamePath + [toolName]
            )
        case let .finished(usage, finishContent, reason, messages):
            handleFinished(usage: usage, finishContent: finishContent, reason: reason, messages: messages)
        case let .iterationCompleted(usage, _, replayedHistory):
            handleIterationCompleted(usage: usage, messages: replayedHistory, origin: event.origin)
        case let .budgetUpdated(budget):
            contextBudget = budget
        }
    }

    private func observeEnvelope(_ event: StreamEvent) {
        if let observed = event.sessionID, sessionID == nil {
            sessionID = observed
        }
        if case let .replayed(checkpointID) = event.origin {
            currentCheckpoint = checkpointID
        }
    }

    private func updateToolCallState(id: String, path: [String], result: ToolResult) {
        let compositeId = compositeToolCallId(localId: id, path: path)
        if let index = toolCalls.firstIndex(where: { $0.id == compositeId }) {
            toolCalls[index].state = result.isError
                ? .failed(result.content)
                : .completed(result.content)
        }
    }

    private func handleFinished(
        usage: TokenUsage, finishContent: String?, reason: FinishReason?, messages: [ChatMessage]
    ) {
        tokenUsage = usage
        finishReason = reason
        history = messages
        if let finishContent, content.isEmpty {
            content = finishContent
        }
    }

    private func handleIterationCompleted(usage: TokenUsage, messages: [ChatMessage], origin: EventOrigin) {
        iterationUsages.append(usage)
        if case .replayed = origin {
            iterationsReplayed += 1
            history = messages
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
        sessionID = nil
        iterationsReplayed = 0
        currentCheckpoint = nil
    }
}
