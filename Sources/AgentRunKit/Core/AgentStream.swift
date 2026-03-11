import Foundation
import Observation

public struct ToolCallInfo: Sendable, Identifiable {
    public let id: String
    public let name: String
    public var state: ToolCallState

    public enum ToolCallState: Sendable {
        case running
        case completed(String)
        case failed(String)
    }
}

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
        requestContext: RequestContext? = nil
    ) {
        send(
            .user(message), history: history, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext
        )
    }

    public func send(
        _ message: ChatMessage,
        history: [ChatMessage] = [],
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil
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
                    requestContext: requestContext
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
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case let .delta(text):
            content += text
        case let .reasoningDelta(text):
            reasoning += text
        case let .toolCallStarted(name, id):
            toolCalls.append(ToolCallInfo(id: id, name: name, state: .running))
        case let .toolCallCompleted(id, _, result):
            if let index = toolCalls.firstIndex(where: { $0.id == id }) {
                toolCalls[index].state = result.isError
                    ? .failed(result.content)
                    : .completed(result.content)
            }
        case .audioData, .audioTranscript, .audioFinished:
            break
        case let .finished(usage, finishContent, reason, hist):
            tokenUsage = usage
            finishReason = reason
            history = hist
            if let finishContent, content.isEmpty {
                content = finishContent
            }
        case .subAgentStarted, .subAgentEvent, .subAgentCompleted:
            break
        case let .iterationCompleted(usage, _):
            iterationUsages.append(usage)
        case .compacted:
            break
        }
    }
}
