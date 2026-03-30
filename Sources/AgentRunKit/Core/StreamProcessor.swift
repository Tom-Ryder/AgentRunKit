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

    var effectiveContent: String {
        content.isEmpty && !audioTranscript.isEmpty ? audioTranscript : content
    }

    func toAssistantMessage() -> AssistantMessage {
        AssistantMessage(
            content: effectiveContent,
            toolCalls: toolCalls,
            reasoning: reasoning.isEmpty ? nil : ReasoningContent(content: reasoning),
            reasoningDetails: reasoningDetails.isEmpty ? nil : reasoningDetails
        )
    }
}

private struct AudioAccumulator {
    var id: String?
    var expiresAt = 0
    var data = Data()
    var transcript = ""

    var finishedEvent: StreamEvent? {
        guard let id else { return nil }
        return .audioFinished(id: id, expiresAt: expiresAt, data: data)
    }
}

private struct StreamAccumulation {
    var content = ""
    var reasoning = ""
    var reasoningDetails = ReasoningDetailAccumulator()
    var toolCalls: [Int: ToolCallAccumulator] = [:]
    var pendingArguments: [Int: String] = [:]
    var audio = AudioAccumulator()
    var usage: TokenUsage?

    mutating func apply(
        _ delta: StreamDelta,
        policy: StreamPolicy,
        totalUsage: inout TokenUsage,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        switch delta {
        case let .content(text):
            content += text
            continuation.yield(.delta(text))
        case let .reasoning(text):
            reasoning += text
            continuation.yield(.reasoningDelta(text))
        case let .reasoningDetails(details):
            reasoningDetails.append(details)
        case let .toolCallStart(index, id, name):
            startToolCall(index: index, id: id, name: name, policy: policy, continuation: continuation)
        case let .toolCallDelta(index, arguments):
            appendToolCallDelta(index: index, arguments: arguments)
        case let .audioStarted(id, expiresAt):
            audio.id = id
            audio.expiresAt = expiresAt
        case let .audioData(data):
            audio.data.append(data)
            continuation.yield(.audioData(data))
        case let .audioTranscript(text):
            audio.transcript += text
            continuation.yield(.audioTranscript(text))
        case let .finished(iterationUsage):
            guard let iterationUsage else { return }
            totalUsage += iterationUsage
            usage = iterationUsage
        }
    }

    func finishAudio(
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        if let event = audio.finishedEvent {
            continuation.yield(event)
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
            usage: usage
        )
    }

    private mutating func startToolCall(
        index: Int,
        id: String,
        name: String,
        policy: StreamPolicy,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        var accumulator = ToolCallAccumulator(id: id, name: name)
        if let buffered = pendingArguments.removeValue(forKey: index) {
            accumulator.arguments = buffered
        }
        toolCalls[index] = accumulator
        if policy.shouldEmitToolStart(name: name) {
            continuation.yield(.toolCallStarted(name: name, id: id))
        }
    }

    private mutating func appendToolCallDelta(index: Int, arguments: String) {
        if toolCalls[index] != nil {
            toolCalls[index]?.arguments += arguments
        } else {
            pendingArguments[index, default: ""] += arguments
        }
    }
}

struct StreamProcessor {
    let client: any LLMClient
    let toolDefinitions: [ToolDefinition]
    let policy: StreamPolicy

    func process(
        messages: [ChatMessage],
        totalUsage: inout TokenUsage,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        requestContext: RequestContext? = nil
    ) async throws -> StreamIteration {
        var state = StreamAccumulation()

        for try await delta in client.stream(
            messages: messages,
            tools: toolDefinitions,
            requestContext: requestContext
        ) {
            try Task.checkCancellation()
            state.apply(delta, policy: policy, totalUsage: &totalUsage, continuation: continuation)
        }

        guard state.pendingArguments.isEmpty else {
            throw AgentError.malformedStream(.orphanedToolCallArguments(indices: state.pendingArguments.keys.sorted()))
        }

        state.finishAudio(continuation: continuation)
        return state.iteration
    }
}
