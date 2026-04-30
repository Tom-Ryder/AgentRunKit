import Foundation

/// Controls which assistant-local reasoning fields are replayed onto outbound Chat Completions requests.
public enum OpenAIChatAssistantReplayProfile: Sendable, Equatable {
    case conservative
    case openRouterReasoningDetails
}

extension OpenAIChatAssistantReplayProfile {
    var emitsReasoningDetails: Bool {
        switch self {
        case .conservative: false
        case .openRouterReasoningDetails: true
        }
    }
}

struct StreamOptions: Encodable {
    let includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

struct RequestReasoning: Encodable {
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

struct ChatCompletionRequest: Encodable {
    let model: String?
    let messages: [RequestMessage]
    let tools: [RequestTool]?
    let toolChoice: OpenAIChatToolChoice?
    let parallelToolCalls: Bool?
    let maxTokens: Int
    let tokenFieldName: String
    let stream: Bool?
    let streamOptions: StreamOptions?
    let responseFormat: ResponseFormat?
    let reasoning: RequestReasoning?
    let extraFields: [String: JSONValue]

    private static let reservedKeys: Set<String> = [
        "model", "messages", "tools", "tool_choice", "reasoning",
        "stream", "stream_options", "response_format",
        "max_tokens", "max_completion_tokens", "parallel_tool_calls"
    ]

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, reasoning
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case stream
        case streamOptions = "stream_options"
        case responseFormat = "response_format"
    }

    func encode(to encoder: any Encoder) throws {
        try ProviderExtraFields.rejectReservedKeys(
            extraFields,
            reservedKeys: Self.reservedKeys,
            debugDescriptionPrefix: "Reserved extraFields keys for OpenAI Chat: ",
            codingPath: encoder.codingPath
        )

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encodeIfPresent(parallelToolCalls, forKey: .parallelToolCalls)
        try container.encodeIfPresent(stream, forKey: .stream)
        try container.encodeIfPresent(streamOptions, forKey: .streamOptions)
        try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)

        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        try dynamicContainer.encode(maxTokens, forKey: DynamicCodingKey(tokenFieldName))
        try ProviderExtraFields.encode(extraFields, to: encoder)
    }
}

struct RequestMessage: Encodable {
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

    enum MessageContent: Encodable {
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

    init(_ message: ChatMessage, replayProfile: OpenAIChatAssistantReplayProfile) throws {
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
            toolCalls = msg.toolCalls.isEmpty ? nil : try msg.toolCalls.map(RequestToolCall.init)
            toolCallId = nil
            name = nil
            reasoningContent = nil
            reasoningDetails = replayProfile.emitsReasoningDetails ? msg.reasoningDetails : nil
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

struct RequestToolCall: Encodable {
    let id: String
    let type: String
    let function: RequestFunction?
    let custom: RequestCustomToolInput?

    init(_ toolCall: ToolCall) throws {
        id = toolCall.id
        type = toolCall.kind.rawValue
        switch toolCall.kind {
        case .function:
            function = RequestFunction(name: toolCall.name, arguments: toolCall.arguments)
            custom = nil
        case .custom:
            function = nil
            custom = RequestCustomToolInput(name: toolCall.name, input: toolCall.arguments)
        }
    }
}

struct RequestFunction: Encodable {
    let name: String
    let arguments: String
}

struct RequestCustomToolInput: Encodable {
    let name: String
    let input: String
}

struct ChatCompletionResponse: Decodable {
    let choices: [ResponseChoice]
    let usage: ResponseUsage?
}

struct ResponseChoice: Decodable {
    let message: ResponseMessage
    let finishReason: String?
}

struct ResponseMessage: Decodable {
    let role: String
    let content: String?
    let toolCalls: [ResponseToolCall]?
    let reasoning: String?
    let reasoningContent: String?
}

struct ResponseToolCall: Decodable {
    let id: String
    let kind: ToolCallKind
    let name: String
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case id, type, function, custom
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type) ?? ToolCallKind.function.rawValue
        guard let kind = ToolCallKind(rawValue: rawType) else {
            throw AgentError.llmError(.featureUnsupported(
                provider: "openai-chat",
                feature: "response tool call type '\(rawType)'"
            ))
        }
        self.kind = kind
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "tool call id is empty"
            )
        }
        switch kind {
        case .function:
            let function = try container.decode(ResponseFunction.self, forKey: .function)
            name = function.name
            arguments = function.arguments
        case .custom:
            let custom = try container.decode(ResponseCustomToolCall.self, forKey: .custom)
            name = custom.name
            arguments = custom.input
        }
    }
}

struct ResponseFunction: Decodable {
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

struct ResponseCustomToolCall: Decodable {
    let name: String
    let input: String

    enum CodingKeys: String, CodingKey {
        case name, input
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        input = try container.decode(String.self, forKey: .input)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "custom tool call name is empty"
            )
        }
    }
}

struct ResponseUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int
    let completionTokensDetails: CompletionTokensDetails?

    var tokenUsage: TokenUsage {
        let reasoning = completionTokensDetails?.reasoningTokens ?? 0
        let output = max(0, completionTokens - reasoning)
        return TokenUsage(input: promptTokens, output: output, reasoning: reasoning)
    }
}

struct CompletionTokensDetails: Decodable {
    let reasoningTokens: Int?
}

struct StreamingChunk: Decodable {
    let choices: [StreamingChoice]?
    let usage: ResponseUsage?
}

struct StreamingChoice: Decodable {
    let delta: StreamingDelta
    let finishReason: String?
}

struct StreamingAudioDelta: Decodable {
    let id: String?
    let data: String?
    let transcript: String?
    let expiresAt: Int?
}

struct StreamingDelta: Decodable {
    let content: String?
    let toolCalls: [StreamingToolCall]?
    let reasoning: String?
    let reasoningContent: String?
    let audio: StreamingAudioDelta?
}

struct StreamingToolCall: Decodable {
    let index: Int
    let id: String?
    let type: String?
    let function: StreamingFunction?
    let custom: StreamingCustom?
}

struct StreamingFunction: Decodable {
    let name: String?
    let arguments: String?
}

struct StreamingCustom: Decodable {
    let name: String?
    let input: String?
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

struct TranscriptionResponse: Decodable {
    let text: String
}
