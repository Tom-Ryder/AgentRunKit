import Foundation

func initialMessages(
    systemPrompt: String?,
    history: [ChatMessage],
    userMessage: ChatMessage
) -> [ChatMessage] {
    var messages: [ChatMessage] = []
    if let systemPrompt {
        messages.append(.system(systemPrompt))
    }
    messages.append(contentsOf: history)
    messages.append(userMessage)
    return messages
}

package extension [ChatMessage] {
    func validateForLLMRequest() throws {
        try validateHistory(using: .llmRequest)
    }

    func validateForAgentHistory() throws {
        try validateHistory(using: .agentHistory)
    }

    func sanitizedTerminalHistory() throws -> [ChatMessage] {
        guard let lastIndex = indices.last,
              case let .assistant(message) = self[lastIndex]
        else {
            return self
        }

        let finishCallCount = message.toolCalls.count(where: { $0.name == "finish" })
        guard finishCallCount > 0 else { return self }
        guard finishCallCount == 1, message.toolCalls.count == 1 else {
            throw AgentError.malformedHistory(.finishMustBeExclusive)
        }

        let sanitizedMessage = message.removingTerminalFinishTool()
        guard !sanitizedMessage.isEmptyAfterRemovingTerminalTools else {
            return Array(dropLast())
        }

        var sanitized = self
        sanitized[lastIndex] = .assistant(sanitizedMessage)
        return sanitized
    }

    func resolvedPrefixForInheritance() throws -> [ChatMessage] {
        let validation = toolCallHistoryValidation(using: .llmRequest)
        switch validation.problem {
        case nil:
            return self
        case let .unfinishedToolCallBatch(_, boundary):
            return Array(prefix(boundary))
        case let .unexpectedToolResult(id, _):
            throw AgentError.malformedHistory(.unexpectedToolResult(id: id))
        case let .toolResultOrderMismatch(expectedID, actualID, _):
            throw AgentError.malformedHistory(
                .toolResultOrderMismatch(expectedID: expectedID, actualID: actualID)
            )
        case .finishMustBeExclusive:
            preconditionFailure("finish must be exclusive in parent history")
        }
    }

    private func validateHistory(using mode: ToolCallHistoryValidationMode) throws {
        switch toolCallHistoryValidation(using: mode).problem {
        case nil:
            return
        case let .unfinishedToolCallBatch(ids, _):
            throw AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ids))
        case let .unexpectedToolResult(id, _):
            throw AgentError.malformedHistory(.unexpectedToolResult(id: id))
        case let .toolResultOrderMismatch(expectedID, actualID, _):
            throw AgentError.malformedHistory(
                .toolResultOrderMismatch(expectedID: expectedID, actualID: actualID)
            )
        case .finishMustBeExclusive:
            throw AgentError.malformedHistory(.finishMustBeExclusive)
        }
    }

    private func toolCallHistoryValidation(using mode: ToolCallHistoryValidationMode) -> ToolCallHistoryValidation {
        var pendingCalls: [ToolCall] = []
        var lastResolvedBoundary = 0

        for (index, message) in enumerated() {
            if pendingCalls.isEmpty {
                switch message {
                case let .assistant(assistant):
                    let finishCallCount = assistant.toolCalls.count(where: { $0.name == "finish" })
                    if mode.requiresExclusiveFinish,
                       finishCallCount > 0,
                       assistant.toolCalls.count != 1 {
                        return ToolCallHistoryValidation(problem: .finishMustBeExclusive(boundary: index))
                    }
                    pendingCalls = assistant.toolCalls
                    if pendingCalls.isEmpty {
                        lastResolvedBoundary = index + 1
                    }
                case let .tool(id, _, _):
                    return ToolCallHistoryValidation(
                        problem: .unexpectedToolResult(id: id, boundary: lastResolvedBoundary)
                    )
                case .system, .user, .userMultimodal:
                    lastResolvedBoundary = index + 1
                }
                continue
            }

            guard case let .tool(id, _, _) = message else {
                return ToolCallHistoryValidation(
                    problem: .unfinishedToolCallBatch(
                        ids: pendingCalls.map(\.id),
                        boundary: lastResolvedBoundary
                    )
                )
            }

            let expectedCall = pendingCalls.removeFirst()
            if expectedCall.id != id {
                if pendingCalls.contains(where: { $0.id == id }) {
                    return ToolCallHistoryValidation(
                        problem: .toolResultOrderMismatch(
                            expectedID: expectedCall.id,
                            actualID: id,
                            boundary: lastResolvedBoundary
                        )
                    )
                }
                return ToolCallHistoryValidation(
                    problem: .unexpectedToolResult(id: id, boundary: lastResolvedBoundary)
                )
            }

            if pendingCalls.isEmpty {
                lastResolvedBoundary = index + 1
            }
        }

        if !pendingCalls.isEmpty {
            return ToolCallHistoryValidation(
                problem: .unfinishedToolCallBatch(
                    ids: pendingCalls.map(\.id),
                    boundary: lastResolvedBoundary
                )
            )
        }

        return ToolCallHistoryValidation(problem: nil)
    }
}

private enum ToolCallHistoryValidationMode {
    case llmRequest
    case agentHistory

    var requiresExclusiveFinish: Bool {
        switch self {
        case .llmRequest:
            false
        case .agentHistory:
            true
        }
    }
}

private struct ToolCallHistoryValidation {
    let problem: ToolCallHistoryProblem?
}

private enum ToolCallHistoryProblem {
    case unfinishedToolCallBatch(ids: [String], boundary: Int)
    case unexpectedToolResult(id: String, boundary: Int)
    case toolResultOrderMismatch(expectedID: String, actualID: String, boundary: Int)
    case finishMustBeExclusive(boundary: Int)
}

private extension AssistantMessage {
    func removingTerminalFinishTool() -> AssistantMessage {
        AssistantMessage(
            content: content,
            toolCalls: toolCalls.filter { $0.name != "finish" },
            tokenUsage: tokenUsage,
            reasoning: reasoning,
            reasoningDetails: reasoningDetails,
            continuity: continuity?.removingResponsesTerminalFinishTool()
        )
    }

    var isEmptyAfterRemovingTerminalTools: Bool {
        content.isEmpty
            && toolCalls.isEmpty
            && reasoning == nil
            && (reasoningDetails?.isEmpty ?? true)
    }
}

private extension AssistantContinuity {
    func removingResponsesTerminalFinishTool() -> AssistantContinuity {
        guard substrate == .responses,
              case let .object(payload) = payload,
              case let .array(output) = payload["output"]
        else {
            return self
        }

        let filteredOutput = output.filter { item in
            guard case let .object(object) = item,
                  case let .string(type) = object["type"],
                  type == "function_call",
                  case let .string(name) = object["name"]
            else {
                return true
            }
            return name != "finish"
        }

        guard filteredOutput.count != output.count else {
            return self
        }

        var updatedPayload = payload
        updatedPayload["output"] = .array(filteredOutput)
        return AssistantContinuity(substrate: substrate, payload: .object(updatedPayload))
            .strippingResponsesContinuationAnchor()
    }
}
