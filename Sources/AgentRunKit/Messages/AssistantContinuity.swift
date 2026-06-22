import Foundation

/// Same-substrate replay state preserved on assistant turns.
public enum ReplaySubstrate: String, Sendable, Equatable, Codable {
    case openAIChatCompletions
    case responses
    case anthropicMessages
    case geminiContents
}

/// Provider-native assistant-turn continuity preserved alongside semantic fields.
public struct AssistantContinuity: Sendable, Equatable, Codable {
    public let substrate: ReplaySubstrate
    public let payload: JSONValue

    public init(
        substrate: ReplaySubstrate,
        payload: JSONValue
    ) {
        self.substrate = substrate
        self.payload = payload
    }
}

extension AssistantContinuity {
    func droppingServerContinuationAnchor() -> AssistantContinuity {
        switch substrate {
        case .responses:
            serverContinuationAnchorRemoved()
        case .anthropicMessages, .openAIChatCompletions, .geminiContents:
            self
        }
    }

    func removingTerminalFinishTool() -> AssistantContinuity {
        switch substrate {
        case .responses:
            terminalFinishToolRemoved()
        case .anthropicMessages, .openAIChatCompletions, .geminiContents:
            self
        }
    }
}
