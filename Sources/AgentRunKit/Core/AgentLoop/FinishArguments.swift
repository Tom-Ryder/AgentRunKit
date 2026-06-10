import Foundation

public struct FinishArguments: Codable, Sendable {
    public let content: String
    public let reason: String?

    public init(content: String, reason: String? = nil) {
        self.content = content
        self.reason = reason
    }
}

func decodeFinishArguments(from arguments: Data) throws -> FinishArguments {
    do {
        return try JSONDecoder().decode(FinishArguments.self, from: arguments)
    } catch {
        throw AgentError.finishDecodingFailed(message: String(describing: error))
    }
}

package let reservedFinishToolDefinition = ToolDefinition(
    name: "finish",
    description: """
    Call this tool when you have completed the task. Pass the final result as content. \
    IMPORTANT: finish must be the only tool call in your message. Never combine it with other tool calls.
    """,
    parametersSchema: .object(
        properties: [
            "content": .string(description: "The final result or response to return to the user"),
            "reason": .string(description: "Optional reason for finishing (e.g., 'completed', 'error')")
                .optional()
        ],
        required: ["content"]
    )
)
