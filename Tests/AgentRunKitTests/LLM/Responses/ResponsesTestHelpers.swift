@testable import AgentRunKit
import Foundation

func encodeRequest(_ request: ResponsesRequest) throws -> [String: Any] {
    let data = try JSONEncoder().encode(request)
    return try decodeHTTPTestJSONObject(from: data)
}

extension ResponsesAPIClient {
    func setLastResponseId(_ id: String?) {
        lastResponseId = id
    }

    func setLastMessageCount(_ count: Int) {
        lastMessageCount = count
    }

    func setLastPrefixSignature(_ signature: Data) {
        lastPrefixSignature = signature
    }

    func setCursorState(
        responseId: String,
        messages: [ChatMessage]
    ) {
        lastResponseId = responseId
        lastMessageCount = messages.count
        lastPrefixSignature = prefixSignature(messages)
    }
}
