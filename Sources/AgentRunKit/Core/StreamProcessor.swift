import Foundation

struct StreamPolicy: Sendable {
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

struct StreamIteration: Sendable {
    let content: String
    let toolCalls: [ToolCall]
    let reasoning: String
    let reasoningDetails: [JSONValue]
}

struct StreamProcessor: Sendable {
    let client: any LLMClient
    let toolDefinitions: [ToolDefinition]
    let policy: StreamPolicy

    func process(
        messages: [ChatMessage],
        totalUsage: inout TokenUsage,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> StreamIteration {
        var contentBuffer = ""
        var reasoningBuffer = ""
        var reasoningDetailsBuffer: [JSONValue] = []
        var accumulators: [Int: ToolCallAccumulator] = [:]
        var pendingArguments: [Int: String] = [:]

        for try await delta in client.stream(messages: messages, tools: toolDefinitions) {
            try Task.checkCancellation()
            switch delta {
            case let .content(text):
                contentBuffer += text
                continuation.yield(.delta(text))

            case let .reasoning(text):
                reasoningBuffer += text
                continuation.yield(.reasoningDelta(text))

            case let .reasoningDetails(details):
                reasoningDetailsBuffer.append(contentsOf: details)

            case let .toolCallStart(index, id, name):
                var accumulator = ToolCallAccumulator(id: id, name: name)
                if let buffered = pendingArguments.removeValue(forKey: index) {
                    accumulator.arguments = buffered
                }
                accumulators[index] = accumulator
                if policy.shouldEmitToolStart(name: name) {
                    continuation.yield(.toolCallStarted(name: name, id: id))
                }

            case let .toolCallDelta(index, arguments):
                if accumulators[index] != nil {
                    accumulators[index]?.arguments += arguments
                } else {
                    pendingArguments[index, default: ""] += arguments
                }

            case let .finished(usage):
                if let usage { totalUsage += usage }
            }
        }

        guard pendingArguments.isEmpty else {
            throw AgentError.malformedStream(.orphanedToolCallArguments(indices: pendingArguments.keys.sorted()))
        }

        let toolCalls = accumulators.keys.sorted().compactMap { index in
            accumulators[index]?.toToolCall()
        }
        return StreamIteration(
            content: contentBuffer,
            toolCalls: toolCalls,
            reasoning: reasoningBuffer,
            reasoningDetails: reasoningDetailsBuffer
        )
    }
}
