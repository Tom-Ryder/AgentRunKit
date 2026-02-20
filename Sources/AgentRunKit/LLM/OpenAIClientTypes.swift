import Foundation

public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(str): try container.encode(str)
        case let .int(num): try container.encode(num)
        case let .double(num): try container.encode(num)
        case let .bool(flag): try container.encode(flag)
        case .null: try container.encodeNil()
        case let .array(arr): try container.encode(arr)
        case let .object(obj): try container.encode(obj)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }

    static func fromJSONObject(_ value: Any) throws -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if let intValue = Int(exactly: number) {
                return .int(intValue)
            }
            return .double(number.doubleValue)
        case let array as [Any]:
            return try .array(array.map { try fromJSONObject($0) })
        case let dict as [String: Any]:
            return try .object(dict.mapValues { try fromJSONObject($0) })
        case is NSNull:
            return .null
        default:
            throw AgentError.llmError(.decodingFailed(description: "Unsupported JSON type: \(type(of: value))"))
        }
    }

    static func extractReasoningDetails(from data: Data) throws -> [JSONValue]? {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any],
              let choices = dict["choices"] as? [[String: Any]],
              let first = choices.first
        else { return nil }
        let message = first["message"] as? [String: Any] ?? first["delta"] as? [String: Any]
        guard let details = message?["reasoning_details"] as? [Any] else { return nil }
        let result = try details.map { try fromJSONObject($0) }
        return result.isEmpty ? nil : result
    }
}

public struct RequestContext: Sendable {
    public let extraFields: [String: JSONValue]
    public let onResponse: (@Sendable (HTTPURLResponse) -> Void)?

    public init(
        extraFields: [String: JSONValue] = [:],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)? = nil
    ) {
        self.extraFields = extraFields
        self.onResponse = onResponse
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ key: String) { stringValue = key }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}

struct StreamOptions: Encodable, Sendable {
    let includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

struct RequestReasoning: Encodable, Sendable {
    let effort: String
    let maxTokens: Int?
    let exclude: Bool?

    enum CodingKeys: String, CodingKey {
        case effort
        case maxTokens = "max_tokens"
        case exclude
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(effort, forKey: .effort)
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(exclude, forKey: .exclude)
    }

    init(_ config: ReasoningConfig) {
        effort = config.effort.rawValue
        maxTokens = config.maxTokens
        exclude = config.exclude
    }
}

struct ChatCompletionRequest: Encodable, Sendable {
    let model: String?
    let messages: [RequestMessage]
    let tools: [RequestTool]?
    let toolChoice: String?
    let maxTokens: Int
    let stream: Bool?
    let streamOptions: StreamOptions?
    let responseFormat: ResponseFormat?
    let reasoning: RequestReasoning?
    let extraFields: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, reasoning
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case stream
        case streamOptions = "stream_options"
        case responseFormat = "response_format"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(stream, forKey: .stream)
        try container.encodeIfPresent(streamOptions, forKey: .streamOptions)
        try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)

        if !extraFields.isEmpty {
            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in extraFields {
                try dynamicContainer.encode(value, forKey: DynamicCodingKey(key))
            }
        }
    }
}

struct RequestMessage: Encodable, Sendable {
    let role: String
    let content: MessageContent?
    let toolCalls: [RequestToolCall]?
    let toolCallId: String?
    let name: String?
    let reasoningContent: String?
    let reasoningDetails: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case reasoningContent = "reasoning_content"
        case reasoningDetails = "reasoning_details"
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
            reasoningContent = nil
            reasoningDetails = nil
        case let .user(text):
            role = "user"
            content = .text(text)
            toolCalls = nil
            toolCallId = nil
            name = nil
            reasoningContent = nil
            reasoningDetails = nil
        case let .userMultimodal(parts):
            role = "user"
            content = .multimodal(parts)
            toolCalls = nil
            toolCallId = nil
            name = nil
            reasoningContent = nil
            reasoningDetails = nil
        case let .assistant(msg):
            role = "assistant"
            content = .text(msg.content)
            toolCalls = msg.toolCalls.isEmpty ? nil : msg.toolCalls.map(RequestToolCall.init)
            toolCallId = nil
            name = nil
            reasoningContent = msg.reasoning?.content
            reasoningDetails = msg.reasoningDetails
        case let .tool(id, toolName, resultContent):
            role = "tool"
            content = .text(resultContent)
            toolCalls = nil
            toolCallId = id
            name = toolName
            reasoningContent = nil
            reasoningDetails = nil
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
    let reasoning: String?
    let reasoningContent: String?
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
    let choices: [StreamingChoice]?
    let usage: ResponseUsage?
}

struct StreamingChoice: Decodable, Sendable {
    let delta: StreamingDelta
    let finishReason: String?
}

struct StreamingDelta: Decodable, Sendable {
    let content: String?
    let toolCalls: [StreamingToolCall]?
    let reasoning: String?
    let reasoningContent: String?
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

public enum TranscriptionAudioFormat: String, Sendable, Codable, CaseIterable {
    case mp3
    case mp4
    case mpeg
    case mpga
    case m4a
    case wav
    case webm

    public var mimeType: String {
        switch self {
        case .mp3, .mpeg, .mpga:
            "audio/mpeg"
        case .mp4, .m4a:
            "audio/mp4"
        case .wav:
            "audio/wav"
        case .webm:
            "audio/webm"
        }
    }

    public var fileExtension: String {
        rawValue
    }
}

public struct TranscriptionOptions: Sendable, Equatable {
    public let language: String?
    public let prompt: String?
    public let temperature: Double?

    public init(language: String? = nil, prompt: String? = nil, temperature: Double? = nil) {
        self.language = language
        self.prompt = prompt
        self.temperature = temperature
    }
}

struct TranscriptionResponse: Decodable, Sendable {
    let text: String
}
