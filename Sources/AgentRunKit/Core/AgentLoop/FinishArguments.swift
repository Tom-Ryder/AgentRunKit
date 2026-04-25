import Foundation

public struct FinishArguments: Codable, Sendable {
    public let content: String
    public let reason: String?

    public init(content: String, reason: String? = nil) {
        self.content = content
        self.reason = reason
    }
}

package let reservedFinishToolDefinition = ToolDefinition(
    name: "finish",
    description: """
    Call this tool when you have completed the task. Pass the final result as content. \
    IMPORTANT: If called alongside other tools, those tools will NOT be executed.
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
