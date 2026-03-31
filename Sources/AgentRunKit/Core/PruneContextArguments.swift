import Foundation

struct PruneContextArguments: Codable {
    let toolCallIds: [String]

    private enum CodingKeys: String, CodingKey {
        case toolCallIds = "tool_call_ids"
    }
}

let prunedToolResultContent = "[pruned]"

struct PruneContextExecutionResult {
    let toolResult: ToolResult
    let historyWasRewritten: Bool
}

func executePruneContext(arguments: Data, messages: inout [ChatMessage]) throws -> PruneContextExecutionResult {
    let decoded = try JSONDecoder().decode(PruneContextArguments.self, from: arguments)
    let targetIds = Set(decoded.toolCallIds)
    var prunedCount = 0

    for index in messages.indices {
        if case let .tool(id, name, content) = messages[index],
           targetIds.contains(id),
           content != prunedToolResultContent {
            messages[index] = .tool(id: id, name: name, content: prunedToolResultContent)
            prunedCount += 1
        }
    }

    return PruneContextExecutionResult(
        toolResult: .success("Pruned \(prunedCount) tool result(s)."),
        historyWasRewritten: prunedCount > 0
    )
}

package let reservedPruneContextToolDefinition = ToolDefinition(
    name: "prune_context",
    description: """
    Remove tool results by ID to free context window capacity. \
    Pass an array of tool call IDs whose results are no longer needed.
    """,
    parametersSchema: .object(
        properties: [
            "tool_call_ids": .array(
                items: .string(description: "Tool call ID to remove"),
                description: "Array of tool call IDs whose results should be pruned"
            ),
        ],
        required: ["tool_call_ids"]
    )
)
