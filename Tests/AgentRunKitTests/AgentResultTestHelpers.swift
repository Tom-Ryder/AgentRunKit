@testable import AgentRunKit
import Foundation

private enum MissingAgentResultContentError: Error {
    case missing(FinishReason)
}

func requireContent(_ result: AgentResult) throws -> String {
    guard let content = result.content else {
        throw MissingAgentResultContentError.missing(result.finishReason)
    }
    return content
}
