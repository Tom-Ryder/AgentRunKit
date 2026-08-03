import Foundation

enum AgentCompletionPolicy {
    case builtInFinish
    case executableTool(name: String)
}

enum TerminalCallDisposition: Equatable {
    case none
    case builtInFinish(ToolCall)
    case executableCompletion(ToolCall)
    case exclusivityViolation(toolName: String, calls: [ToolCall])
}

extension AgentCompletionPolicy {
    var allowsContentOnlyTermination: Bool {
        switch self {
        case .builtInFinish: true
        case .executableTool: false
        }
    }

    func validateIdentity(of outcome: AgentTerminalOutcome) throws {
        switch self {
        case .builtInFinish:
            throw AgentCheckpointError.completionToolMismatch(checkpointed: outcome.toolName, live: nil)
        case let .executableTool(name):
            guard name == outcome.toolName else {
                throw AgentCheckpointError.completionToolMismatch(checkpointed: outcome.toolName, live: name)
            }
        }
    }

    func classify(_ toolCalls: [ToolCall]) throws -> TerminalCallDisposition {
        let includesReservedFinish = toolCalls.contains { $0.name == "finish" }
        guard !includesReservedFinish || toolCalls.count == 1 else {
            throw AgentError.malformedHistory(.finishMustBeExclusive)
        }
        switch self {
        case .builtInFinish:
            guard includesReservedFinish else { return .none }
            return .builtInFinish(toolCalls[0])
        case let .executableTool(name):
            guard toolCalls.contains(where: { $0.name == name }) else { return .none }
            guard toolCalls.count == 1 else {
                return .exclusivityViolation(toolName: name, calls: toolCalls)
            }
            return .executableCompletion(toolCalls[0])
        }
    }
}
