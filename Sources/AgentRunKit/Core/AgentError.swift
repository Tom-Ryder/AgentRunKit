import Foundation

public enum MalformedStreamReason: Sendable, Equatable, CustomStringConvertible {
    case toolCallDeltaWithoutStart(index: Int)
    case missingToolCallId(index: Int)
    case missingToolCallName(index: Int)

    public var description: String {
        switch self {
        case let .toolCallDeltaWithoutStart(index):
            "Tool call delta at index \(index) without prior start"
        case let .missingToolCallId(index):
            "Tool call at index \(index) missing ID"
        case let .missingToolCallName(index):
            "Tool call at index \(index) missing name"
        }
    }
}

public enum AgentError: Error, Sendable, Equatable, LocalizedError {
    case maxIterationsReached(iterations: Int)
    case toolNotFound(name: String)
    case toolDecodingFailed(tool: String, message: String)
    case toolEncodingFailed(tool: String, message: String)
    case finishDecodingFailed(message: String)
    case structuredOutputDecodingFailed(message: String)
    case toolTimeout(tool: String)
    case toolExecutionFailed(tool: String, message: String)
    case llmError(TransportError)
    case malformedStream(MalformedStreamReason)

    public var errorDescription: String? {
        switch self {
        case let .maxIterationsReached(iterations):
            "Agent reached maximum iterations (\(iterations))"
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
        case let .malformedStream(reason):
            "Malformed stream: \(reason)"
        }
    }

    public var feedbackMessage: String {
        switch self {
        case let .toolNotFound(name): "Error: Tool '\(name)' does not exist."
        case let .toolDecodingFailed(tool, message): "Error: Invalid arguments for '\(tool)': \(message)"
        case let .toolTimeout(tool): "Error: Tool '\(tool)' timed out."
        case let .toolExecutionFailed(tool, message): "Error: Tool '\(tool)' failed: \(message)"
        case let .toolEncodingFailed(tool, message): "Error: Failed to encode '\(tool)' output: \(message)"
        case let .maxIterationsReached(count): "Error: Agent reached maximum iterations (\(count))."
        case let .finishDecodingFailed(message): "Error: Failed to decode finish arguments: \(message)"
        case let .structuredOutputDecodingFailed(message): "Error: Failed to decode structured output: \(message)"
        case let .llmError(transportError): "Error: LLM request failed: \(transportError)"
        case let .malformedStream(reason): "Error: Malformed stream: \(reason)"
        }
    }
}
