import Foundation

/// Describes how a message history violates tool-call sequencing rules.
public enum MalformedHistoryReason: Sendable, Equatable, CustomStringConvertible {
    case unfinishedToolCallBatch(ids: [String])
    case unexpectedToolResult(id: String)
    case toolResultOrderMismatch(expectedID: String, actualID: String)
    case finishMustBeExclusive

    public var description: String {
        switch self {
        case let .unfinishedToolCallBatch(ids):
            "Assistant tool calls \(ids) were not immediately followed by matching tool results"
        case let .unexpectedToolResult(id):
            "Tool result '\(id)' appeared without a matching assistant tool call"
        case let .toolResultOrderMismatch(expectedID, actualID):
            "Expected tool result '\(expectedID)' but received '\(actualID)'"
        case .finishMustBeExclusive:
            "finish must be the only tool call in its assistant message"
        }
    }
}

/// Describes how an SSE stream was malformed.
public enum MalformedStreamReason: Sendable, Equatable, CustomStringConvertible {
    case toolCallDeltaWithoutStart(index: Int)
    case missingToolCallId(index: Int)
    case missingToolCallName(index: Int)
    case orphanedToolCallArguments(indices: [Int])
    case conflictingAssistantContinuity
    case finalizedSemanticStateDiverged
    case responsesStreamIncomplete

    public var description: String {
        switch self {
        case let .toolCallDeltaWithoutStart(index):
            "Tool call delta at index \(index) without prior start"
        case let .missingToolCallId(index):
            "Tool call at index \(index) missing ID"
        case let .missingToolCallName(index):
            "Tool call at index \(index) missing name"
        case let .orphanedToolCallArguments(indices):
            "Tool call arguments at indices \(indices) never received start event"
        case .conflictingAssistantContinuity:
            "Conflicting assistant continuity payloads received for one streamed turn"
        case .finalizedSemanticStateDiverged:
            "Finalized semantic state contradicted previously emitted semantic deltas"
        case .responsesStreamIncomplete:
            "Responses stream ended before completed response"
        }
    }
}

/// Errors thrown by the agent loop.
public enum AgentError: Error, Sendable, Equatable, LocalizedError {
    case toolNotFound(name: String)
    case toolDecodingFailed(tool: String, message: String)
    case toolEncodingFailed(tool: String, message: String)
    case finishDecodingFailed(message: String)
    case structuredOutputDecodingFailed(message: String)
    case toolTimeout(tool: String)
    case toolExecutionFailed(tool: String, message: String)
    case llmError(TransportError)
    case malformedHistory(MalformedHistoryReason)
    case malformedStream(MalformedStreamReason)
    case schemaInferenceFailed(type: String, message: String)
    case maxDepthExceeded(depth: Int)
    case contextBudgetWindowSizeUnavailable

    public var errorDescription: String? {
        switch self {
        case let .toolNotFound(name):
            "Tool '\(name)' not found"
        case let .toolDecodingFailed(tool, message):
            "Failed to decode arguments for tool '\(tool)': \(message)"
        case let .toolEncodingFailed(tool, message):
            "Failed to encode output for tool '\(tool)': \(message)"
        case let .finishDecodingFailed(message):
            "Failed to decode finish arguments: \(message)"
        case let .structuredOutputDecodingFailed(message):
            "Failed to decode structured output: \(message)"
        case let .toolTimeout(tool):
            "Tool '\(tool)' timed out"
        case let .toolExecutionFailed(tool, message):
            "Tool '\(tool)' execution failed: \(message)"
        case let .llmError(transportError):
            "LLM request failed: \(transportError)"
        case let .malformedHistory(reason):
            "Malformed history: \(reason)"
        case let .malformedStream(reason):
            "Malformed stream: \(reason)"
        case let .schemaInferenceFailed(type, message):
            "Schema inference failed for '\(type)': \(message)"
        case let .maxDepthExceeded(depth):
            "Sub-agent max depth exceeded (current depth: \(depth))"
        case .contextBudgetWindowSizeUnavailable:
            "Context budget requires a client contextWindowSize for usage-based features"
        }
    }

    public var feedbackMessage: String {
        switch self {
        case let .toolNotFound(name): "Error: Tool '\(name)' does not exist."
        case let .toolDecodingFailed(tool, message): "Error: Invalid arguments for '\(tool)': \(message)"
        case let .toolTimeout(tool): "Error: Tool '\(tool)' timed out."
        case let .toolExecutionFailed(tool, message): "Error: Tool '\(tool)' failed: \(message)"
        case let .toolEncodingFailed(tool, message): "Error: Failed to encode '\(tool)' output: \(message)"
        case let .finishDecodingFailed(message): "Error: Failed to decode finish arguments: \(message)"
        case let .structuredOutputDecodingFailed(message): "Error: Failed to decode structured output: \(message)"
        case let .llmError(transportError): "Error: LLM request failed: \(transportError)"
        case let .malformedHistory(reason): "Error: Malformed history: \(reason)"
        case let .malformedStream(reason): "Error: Malformed stream: \(reason)"
        case let .schemaInferenceFailed(type, message): "Error: Schema inference failed for '\(type)': \(message)"
        case let .maxDepthExceeded(depth): "Error: Sub-agent max depth exceeded (current depth: \(depth))."
        case .contextBudgetWindowSizeUnavailable:
            "Error: Context budget requires a client contextWindowSize for usage-based features."
        }
    }
}
