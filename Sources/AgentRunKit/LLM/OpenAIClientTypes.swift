import Foundation

struct StreamOptions: Encodable, Sendable {
    let includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [RequestMessage]
    let tools: [RequestTool]?
    let toolChoice: String?
    let maxTokens: Int
    let stream: Bool?
    let streamOptions: StreamOptions?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case stream
        case streamOptions = "stream_options"
        case responseFormat = "response_format"
    }
}

struct RequestMessage: Encodable, Sendable {
    let role: String
    let content: MessageContent?
    let toolCalls: [RequestToolCall]?
    let toolCallId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    enum MessageContent: Encodable, Sendable {
        case text(String)
        case multimodal([ContentPart])

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .text(string):
                try container.encode(string)
            case let .multimodal(parts):
                try container.encode(parts)
            }
        }
    }

    init(_ message: ChatMessage) {
        switch message {
        case let .system(text):
            role = "system"
            content = .text(text)
            toolCalls = nil
            toolCallId = nil
            name = nil
        case let .user(text):
            role = "user"
            content = .text(text)
            toolCalls = nil
            toolCallId = nil
            name = nil
        case let .userMultimodal(parts):
            role = "user"
            content = .multimodal(parts)
            toolCalls = nil
            toolCallId = nil
            name = nil
        case let .assistant(msg):
            role = "assistant"
            content = msg.content.isEmpty ? nil : .text(msg.content)
            toolCalls = msg.toolCalls.isEmpty ? nil : msg.toolCalls.map(RequestToolCall.init)
            toolCallId = nil
            name = nil
        case let .tool(id, toolName, resultContent):
            role = "tool"
            content = .text(resultContent)
            toolCalls = nil
            toolCallId = id
            name = toolName
        }
    }
}

struct RequestToolCall: Encodable, Sendable {
    let id: String
    let type: String
    let function: RequestFunction

    init(_ toolCall: ToolCall) {
        id = toolCall.id
        type = "function"
        function = RequestFunction(name: toolCall.name, arguments: toolCall.arguments)
    }
}

struct RequestFunction: Encodable, Sendable {
    let name: String
    let arguments: String
}

struct RequestTool: Encodable, Sendable {
    let type: String
    let function: RequestToolFunction

    init(_ definition: ToolDefinition) {
        type = "function"
        function = RequestToolFunction(definition)
    }
}

struct RequestToolFunction: Encodable, Sendable {
    let name: String
    let description: String
    let parameters: JSONSchema

    init(_ definition: ToolDefinition) {
        name = definition.name
        description = definition.description
        parameters = definition.parametersSchema
    }
}

struct ChatCompletionResponse: Decodable, Sendable {
    let choices: [ResponseChoice]
    let usage: ResponseUsage?
}

struct ResponseChoice: Decodable, Sendable {
    let message: ResponseMessage
    let finishReason: String?
}

struct ResponseMessage: Decodable, Sendable {
    let role: String
    let content: String?
    let toolCalls: [ResponseToolCall]?
}

struct ResponseToolCall: Decodable, Sendable {
    let id: String
    let type: String
    let function: ResponseFunction

    enum CodingKeys: String, CodingKey {
        case id, type, function
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        function = try container.decode(ResponseFunction.self, forKey: .function)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "tool call id is empty"
            )
        }
    }
}

struct ResponseFunction: Decodable, Sendable {
    let name: String
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case name, arguments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decode(String.self, forKey: .arguments)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "function name is empty"
            )
        }
    }
}

struct ResponseUsage: Decodable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let completionTokensDetails: CompletionTokensDetails?
}

struct CompletionTokensDetails: Decodable, Sendable {
    let reasoningTokens: Int?
}

struct StreamingChunk: Decodable, Sendable {
    let choices: [StreamingChoice]
    let usage: ResponseUsage?
}

struct StreamingChoice: Decodable, Sendable {
    let delta: StreamingDelta
    let finishReason: String?
}

struct StreamingDelta: Decodable, Sendable {
    let content: String?
    let toolCalls: [StreamingToolCall]?
}

struct StreamingToolCall: Decodable, Sendable {
    let index: Int
    let id: String?
    let function: StreamingFunction?
}

struct StreamingFunction: Decodable, Sendable {
    let name: String?
    let arguments: String?
}
