import Foundation

struct StreamPolicy {
    let terminalToolName: String?
    let terminateWhenNoToolCalls: Bool
    let emitToolStartForTerminalTool: Bool
    let executeTerminalTool: Bool

    static let agent = StreamPolicy(
        terminalToolName: "finish",
        terminateWhenNoToolCalls: false,
        emitToolStartForTerminalTool: false,
        executeTerminalTool: false
    )

    static let chat = StreamPolicy(
        terminalToolName: nil,
        terminateWhenNoToolCalls: true,
        emitToolStartForTerminalTool: true,
        executeTerminalTool: true
    )

    func shouldEmitToolStart(name: String) -> Bool {
        guard let terminalToolName, terminalToolName == name else { return true }
        return emitToolStartForTerminalTool
    }

    func shouldExecuteTool(name: String) -> Bool {
        guard let terminalToolName, terminalToolName == name else { return true }
        return executeTerminalTool
    }

    func executableToolCalls(from toolCalls: [ToolCall]) -> [ToolCall] {
        toolCalls.filter { shouldExecuteTool(name: $0.name) }
    }

    func shouldTerminateAfterIteration(toolCalls: [ToolCall]) -> Bool {
        if let terminalToolName, toolCalls.contains(where: { $0.name == terminalToolName }) {
            return true
        }
        if terminateWhenNoToolCalls, toolCalls.isEmpty {
            return true
        }
        return false
    }
}

struct StreamIteration {
    let content: String
    let toolCalls: [ToolCall]
    let reasoning: String
    let reasoningDetails: [JSONValue]
    let audioTranscript: String
    let usage: TokenUsage?
    let continuity: AssistantContinuity?

    var effectiveContent: String {
        content.isEmpty && !audioTranscript.isEmpty ? audioTranscript : content
    }

    func toAssistantMessage() -> AssistantMessage {
        AssistantMessage(
            content: effectiveContent,
            toolCalls: toolCalls,
            tokenUsage: usage,
            reasoning: reasoning.isEmpty ? nil : ReasoningContent(content: reasoning),
            reasoningDetails: reasoningDetails.isEmpty ? nil : reasoningDetails,
            continuity: continuity
        )
    }
}

private struct AudioAccumulator {
    var id: String?
    var expiresAt = 0
    var data = Data()
    var transcript = ""

    func finishedEvent(eventFactory: StreamEventFactory) -> StreamEvent? {
        guard let id else { return nil }
        return eventFactory.make(.audioFinished(id: id, expiresAt: expiresAt, data: data))
    }
}

private struct StreamAccumulation {
    let eventFactory: StreamEventFactory
    let started: ContinuousClock.Instant = .now
    var content = ""
    var reasoning = ""
    var reasoningDetails = ReasoningDetailAccumulator()
    var toolCalls: [Int: ToolCallAccumulator] = [:]
    var pendingArguments: [Int: String] = [:]
    var audio = AudioAccumulator()
    var usage: TokenUsage?
    var continuity: AssistantContinuity?
    var yieldedEvent = false
    var eventsObserved = 0
    var sawFinished = false

    mutating func apply(
        _ input: RunStreamElement,
        policy: StreamPolicy,
        totalUsage: inout TokenUsage,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        eventObserver: (@Sendable (StreamEvent) -> Void)?
    ) throws {
        switch input {
        case let .delta(delta):
            apply(
                delta,
                policy: policy,
                totalUsage: &totalUsage,
                continuation: continuation,
                eventObserver: eventObserver
            )
        case let .finalizedContinuity(continuity):
            try setFinalizedContinuity(continuity)
        }
    }

    private mutating func apply(
        _ delta: StreamDelta,
        policy: StreamPolicy,
        totalUsage: inout TokenUsage,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        eventObserver: (@Sendable (StreamEvent) -> Void)?
    ) {
        switch delta {
        case let .content(text):
            content += text
            yield(.delta(text), continuation: continuation, eventObserver: eventObserver)
        case let .reasoning(text):
            reasoning += text
            yield(.reasoningDelta(text), continuation: continuation, eventObserver: eventObserver)
        case let .reasoningDetails(details):
            reasoningDetails.append(details)
        case let .toolCallStart(index, id, name, kind):
            startToolCall(
                index: index, id: id, name: name, kind: kind, policy: policy,
                continuation: continuation, eventObserver: eventObserver
            )
        case let .toolCallDelta(index, arguments):
            appendToolCallDelta(index: index, arguments: arguments)
        case let .audioStarted(id, expiresAt):
            audio.id = id
            audio.expiresAt = expiresAt
        case let .audioData(data):
            audio.data.append(data)
            yield(.audioData(data), continuation: continuation, eventObserver: eventObserver)
        case let .audioTranscript(text):
            audio.transcript += text
            yield(.audioTranscript(text), continuation: continuation, eventObserver: eventObserver)
        case let .finished(iterationUsage):
            sawFinished = true
            guard let iterationUsage else { return }
            totalUsage += iterationUsage
            usage = iterationUsage
        }
    }

    private mutating func setFinalizedContinuity(_ newValue: AssistantContinuity) throws {
        guard continuity == nil else {
            throw streamFailure(reason: .conflictingAssistantContinuity)
        }
        continuity = newValue
    }

    mutating func finishAudio(
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        eventObserver: (@Sendable (StreamEvent) -> Void)?
    ) {
        if let event = audio.finishedEvent(eventFactory: eventFactory) {
            yieldedEvent = true
            eventsObserved += 1
            continuation.yield(event)
            eventObserver?(event)
        }
    }

    var iteration: StreamIteration {
        let finalizedToolCalls = toolCalls.keys.sorted().compactMap { index in
            toolCalls[index]?.toToolCall()
        }
        return StreamIteration(
            content: content,
            toolCalls: finalizedToolCalls,
            reasoning: reasoning,
            reasoningDetails: reasoningDetails.consolidated(),
            audioTranscript: audio.transcript,
            usage: usage,
            continuity: continuity
        )
    }

    private mutating func startToolCall(
        index: Int,
        id: String,
        name: String,
        kind: ToolCallKind,
        policy: StreamPolicy,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        eventObserver: (@Sendable (StreamEvent) -> Void)?
    ) {
        guard toolCalls[index] == nil else { return }
        var accumulator = ToolCallAccumulator(id: id, name: name, kind: kind)
        if let buffered = pendingArguments.removeValue(forKey: index) {
            accumulator.arguments = buffered
        }
        toolCalls[index] = accumulator
        if policy.shouldEmitToolStart(name: name) {
            yield(.toolCallStarted(name: name, id: id), continuation: continuation, eventObserver: eventObserver)
        }
    }

    private mutating func appendToolCallDelta(index: Int, arguments: String) {
        if toolCalls[index] != nil {
            toolCalls[index]?.arguments += arguments
        } else {
            pendingArguments[index, default: ""] += arguments
        }
    }

    var diagnostics: StreamFailureDiagnostics {
        StreamFailureDiagnostics(
            elapsed: ContinuousClock.now - started,
            eventsObserved: eventsObserved,
            lastEvent: nil
        )
    }

    var completionDiagnostics: StreamCompletionDiagnostics {
        StreamCompletionDiagnostics(elapsed: ContinuousClock.now - started, eventsObserved: eventsObserved)
    }

    func streamFailure(reason: MalformedStreamReason) -> AgentError {
        AgentError.llmError(.streamFailed(.malformedStream(reason: reason, diagnostics: diagnostics)))
    }

    private mutating func yield(
        _ kind: StreamEvent.Kind,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        eventObserver: (@Sendable (StreamEvent) -> Void)?
    ) {
        yieldedEvent = true
        eventsObserved += 1
        let event = eventFactory.make(kind)
        continuation.yield(event)
        eventObserver?(event)
    }
}

struct StreamProcessor {
    let client: any LLMClient
    let toolDefinitions: [ToolDefinition]
    let policy: StreamPolicy
    let eventFactory: StreamEventFactory

    func process(
        messages: [ChatMessage],
        totalUsage: inout TokenUsage,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        requestContext: RequestContext? = nil,
        requestMode: RunRequestMode = .auto
    ) async throws -> StreamIteration {
        var emittedOutput = false
        return try await process(
            messages: messages,
            totalUsage: &totalUsage,
            emittedOutput: &emittedOutput,
            continuation: continuation,
            requestContext: requestContext,
            requestMode: requestMode
        )
    }

    func process(
        messages: [ChatMessage],
        totalUsage: inout TokenUsage,
        emittedOutput: inout Bool,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        requestContext: RequestContext? = nil,
        requestMode: RunRequestMode = .auto
    ) async throws -> StreamIteration {
        var state = StreamAccumulation(eventFactory: eventFactory)
        let eventObserver = requestContext?.onStreamEvent
        let completionObserver = requestContext?.onStreamComplete

        do {
            for try await input in client.streamForRun(
                messages: messages,
                tools: toolDefinitions,
                requestContext: requestContext,
                requestMode: requestMode
            ) {
                try Task.checkCancellation()
                try state.apply(
                    input,
                    policy: policy,
                    totalUsage: &totalUsage,
                    continuation: continuation,
                    eventObserver: eventObserver
                )
            }
        } catch is CancellationError {
            emittedOutput = state.yieldedEvent
            completionObserver?(.cancelled)
            throw CancellationError()
        } catch let AgentError.llmError(.streamFailed(failure)) {
            emittedOutput = state.yieldedEvent
            completionObserver?(.failed(failure))
            throw AgentError.llmError(.streamFailed(failure))
        } catch {
            emittedOutput = state.yieldedEvent
            throw error
        }

        if Task.isCancelled {
            emittedOutput = state.yieldedEvent
            completionObserver?(.cancelled)
            throw CancellationError()
        }

        guard state.pendingArguments.isEmpty else {
            emittedOutput = state.yieldedEvent
            let failure = StreamFailure.malformedStream(
                reason: .orphanedToolCallArguments(indices: state.pendingArguments.keys.sorted()),
                diagnostics: state.diagnostics
            )
            completionObserver?(.failed(failure))
            throw AgentError.llmError(.streamFailed(failure))
        }
        guard state.sawFinished else {
            emittedOutput = state.yieldedEvent
            let failure = StreamFailure.finishedDeltaMissing(diagnostics: state.diagnostics)
            completionObserver?(.failed(failure))
            throw AgentError.llmError(.streamFailed(failure))
        }

        emittedOutput = true
        state.finishAudio(continuation: continuation, eventObserver: eventObserver)
        completionObserver?(.success(diagnostics: state.completionDiagnostics))
        return state.iteration
    }
}
