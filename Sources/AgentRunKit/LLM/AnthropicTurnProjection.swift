import Foundation

struct AnthropicTurnProjection {
    let orderedBlocks: [JSONValue]

    init(responseBlocks: [AnthropicResponseBlock]) {
        orderedBlocks = responseBlocks.map(Self.responseBlockToJSON)
    }

    init(orderedBlocks: [JSONValue]) {
        self.orderedBlocks = orderedBlocks
    }

    var continuity: AssistantContinuity {
        AssistantContinuity(
            substrate: .anthropicMessages,
            payload: .object(["content": .array(orderedBlocks)])
        )
    }

    func project(usage: TokenUsage) throws -> AssistantMessage {
        var content = ""
        var toolCalls: [ToolCall] = []
        var reasoningText: String?
        var reasoningDetails: [JSONValue] = []

        for block in orderedBlocks {
            guard case let .object(dict) = block,
                  case let .string(type) = dict["type"] else { continue }
            switch type {
            case "text":
                if case let .string(text) = dict["text"] {
                    content += text
                }
            case "thinking":
                if case let .string(thinking) = dict["thinking"] {
                    reasoningText = reasoningText.map { $0 + "\n" + thinking } ?? thinking
                }
                reasoningDetails.append(block)
            case "tool_use":
                guard case let .string(id) = dict["id"],
                      case let .string(name) = dict["name"],
                      let input = dict["input"] else { continue }
                let encoded = try JSONEncoder().encode(input)
                guard let arguments = String(data: encoded, encoding: .utf8) else {
                    preconditionFailure("JSONEncoder produced invalid UTF-8")
                }
                toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
            default:
                break
            }
        }

        return AssistantMessage(
            content: content,
            toolCalls: toolCalls,
            tokenUsage: usage,
            reasoning: reasoningText.map { ReasoningContent(content: $0) },
            reasoningDetails: reasoningDetails.isEmpty ? nil : reasoningDetails,
            continuity: orderedBlocks.isEmpty ? nil : continuity
        )
    }

    static func replayBlocks(from continuity: AssistantContinuity) throws -> [AnthropicContentBlock] {
        guard continuity.substrate == .anthropicMessages else {
            throw AgentError.llmError(.other(
                "Anthropic replay requested for non-anthropicMessages continuity"
            ))
        }
        guard case let .object(payload) = continuity.payload,
              case let .array(blocks) = payload["content"] else {
            throw AgentError.llmError(.other("Malformed Anthropic continuity payload"))
        }
        guard !blocks.isEmpty else {
            throw AgentError.llmError(.other("Empty Anthropic continuity payload"))
        }

        return try blocks.map { blockValue -> AnthropicContentBlock in
            guard case let .object(dict) = blockValue,
                  case let .string(type) = dict["type"] else {
                throw AgentError.llmError(.other("Malformed Anthropic continuity block"))
            }
            switch type {
            case "text":
                guard case let .string(text) = dict["text"] else {
                    throw AgentError.llmError(.other("Malformed Anthropic text block in continuity"))
                }
                return .text(text)
            case "thinking":
                guard case let .string(thinking) = dict["thinking"],
                      case let .string(signature) = dict["signature"] else {
                    throw AgentError.llmError(.other("Malformed Anthropic thinking block in continuity"))
                }
                return .thinking(thinking: thinking, signature: signature)
            case "tool_use":
                guard case let .string(id) = dict["id"],
                      case let .string(name) = dict["name"],
                      let input = dict["input"] else {
                    throw AgentError.llmError(.other("Malformed Anthropic tool_use block in continuity"))
                }
                return .toolUse(id: id, name: name, input: input)
            default:
                throw AgentError.llmError(.other(
                    "Unknown Anthropic block type in continuity: \(type)"
                ))
            }
        }
    }

    private static func responseBlockToJSON(_ block: AnthropicResponseBlock) -> JSONValue {
        switch block {
        case let .text(text):
            .object(["type": .string("text"), "text": .string(text)])
        case let .thinking(thinking, signature):
            .object([
                "type": .string("thinking"),
                "thinking": .string(thinking),
                "signature": .string(signature),
            ])
        case let .toolUse(id, name, input):
            .object([
                "type": .string("tool_use"),
                "id": .string(id),
                "name": .string(name),
                "input": input,
            ])
        }
    }
}
