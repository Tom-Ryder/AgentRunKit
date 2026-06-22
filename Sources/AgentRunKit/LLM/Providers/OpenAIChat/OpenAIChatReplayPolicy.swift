import Foundation

enum OpenAIChatReplayCondition: Equatable {
    case always
    case toolCallTurnsOnly

    func permits(_ message: AssistantMessage) -> Bool {
        switch self {
        case .always:
            true
        case .toolCallTurnsOnly:
            !message.toolCalls.isEmpty
        }
    }
}

struct OpenAIChatReplayPolicy: Equatable {
    let reasoningContent: OpenAIChatReplayCondition?
    let reasoningDetails: OpenAIChatReplayCondition?

    static func resolve(profile: OpenAIChatAssistantReplayProfile) -> OpenAIChatReplayPolicy {
        switch profile {
        case .conservative:
            OpenAIChatReplayPolicy(reasoningContent: nil, reasoningDetails: nil)
        case .openRouterReasoningDetails:
            OpenAIChatReplayPolicy(reasoningContent: nil, reasoningDetails: .always)
        case .reasoningContent:
            OpenAIChatReplayPolicy(reasoningContent: .toolCallTurnsOnly, reasoningDetails: nil)
        }
    }

    func resolvedFields(for message: AssistantMessage) -> (reasoningContent: String?, reasoningDetails: [JSONValue]?) {
        let content = reasoningContent.flatMap { condition -> String? in
            guard condition.permits(message) else { return nil }
            return message.reasoning.flatMap { $0.content.isEmpty ? nil : $0.content }
        }
        let details = reasoningDetails.flatMap { condition -> [JSONValue]? in
            condition.permits(message) ? message.reasoningDetails : nil
        }
        return (content, details)
    }
}
