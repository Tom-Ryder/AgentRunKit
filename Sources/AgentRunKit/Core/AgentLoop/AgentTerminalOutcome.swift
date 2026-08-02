import Foundation

/// Committed result of an agent run that completed through its configured completion tool.
public struct AgentTerminalOutcome: Sendable, Codable, Equatable {
    public let content: String
    public let toolName: String

    public init(content: String, toolName: String) {
        precondition(!toolName.isEmpty, "toolName must be non-empty")
        self.content = content
        self.toolName = toolName
    }

    private enum CodingKeys: String, CodingKey { case content, toolName }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let content = try container.decode(String.self, forKey: .content)
        let toolName = try container.decode(String.self, forKey: .toolName)
        guard !toolName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .toolName, in: container,
                debugDescription: "AgentTerminalOutcome.toolName must be non-empty"
            )
        }
        self.init(content: content, toolName: toolName)
    }
}
