import Foundation

struct AnthropicRequest: Encodable {
    var model: String?
    let messages: [AnthropicMessage]
    let system: [AnthropicSystemBlock]?
    let tools: [AnthropicToolDefinition]?
    let toolChoice: AnthropicToolChoice?
    let maxTokens: Int
    let stream: Bool?
    let thinking: AnthropicThinkingConfig?
    let outputConfig: AnthropicOutputConfig?
    let extraFields: [String: JSONValue]

    private static let validExtraFields: Set<String> = [
        "temperature", "top_p", "top_k", "stop_sequences", "metadata", "container", "service_tier"
    ]

    enum CodingKeys: String, CodingKey {
        case model, messages, system, tools, stream, thinking
        case toolChoice = "tool_choice"
        case outputConfig = "output_config"
        case maxTokens = "max_tokens"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(system, forKey: .system)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(stream, forKey: .stream)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(outputConfig, forKey: .outputConfig)

        if !extraFields.isEmpty {
            let invalidKeys = extraFields.keys.filter { !Self.validExtraFields.contains($0) }
            if !invalidKeys.isEmpty {
                throw EncodingError.invalidValue(
                    extraFields,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Invalid extraFields for Anthropic API: "
                            + invalidKeys.sorted().joined(separator: ", ")
                    )
                )
            }
            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in extraFields {
                try dynamicContainer.encode(value, forKey: DynamicCodingKey(key))
            }
        }
    }
}

enum AnthropicRole: String, Encodable {
    case user, assistant
}

struct AnthropicMessage: Encodable {
    let role: AnthropicRole
    var content: AnthropicMessageContent
}

enum AnthropicMessageContent: Encodable {
    case text(String)
    case blocks([AnthropicContentBlock])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(string):
            try container.encode(string)
        case let .blocks(blocks):
            try container.encode(blocks)
        }
    }
}

enum AnthropicContentBlock: Encodable {
    case text(String, cacheControl: CacheControl? = nil)
    case thinking(thinking: String, signature: String)
    case toolUse(id: String, name: String, input: JSONValue, cacheControl: CacheControl? = nil)
    case toolResult(toolUseId: String, content: String, isError: Bool, cacheControl: CacheControl? = nil)
    case image(mediaType: String, data: String, cacheControl: CacheControl? = nil)
    case document(mediaType: String, data: String, cacheControl: CacheControl? = nil)
    case opaque(JSONValue)

    private enum BlockType: String, Encodable {
        case text, thinking, toolUse = "tool_use", toolResult = "tool_result"
        case image, document
    }

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, signature, id, name, input, source
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
        case cacheControl = "cache_control"
    }

    private enum SourceKeys: String, CodingKey {
        case type, mediaType = "media_type", data
    }

    func encode(to encoder: any Encoder) throws {
        if case let .opaque(raw) = self {
            try raw.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text, cacheControl):
            try container.encode(BlockType.text, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case let .thinking(thinking, signature):
            try container.encode(BlockType.thinking, forKey: .type)
            try container.encode(thinking, forKey: .thinking)
            try container.encode(signature, forKey: .signature)
        case let .toolUse(id, name, input, cacheControl):
            try container.encode(BlockType.toolUse, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
            try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case let .toolResult(toolUseId, content, isError, cacheControl):
            try container.encode(BlockType.toolResult, forKey: .type)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(content, forKey: .content)
            if isError {
                try container.encode(true, forKey: .isError)
            }
            try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case let .image(mediaType, data, cacheControl):
            try container.encode(BlockType.image, forKey: .type)
            var sourceContainer = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try sourceContainer.encode("base64", forKey: .type)
            try sourceContainer.encode(mediaType, forKey: .mediaType)
            try sourceContainer.encode(data, forKey: .data)
            try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case let .document(mediaType, data, cacheControl):
            try container.encode(BlockType.document, forKey: .type)
            var sourceContainer = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try sourceContainer.encode("base64", forKey: .type)
            try sourceContainer.encode(mediaType, forKey: .mediaType)
            try sourceContainer.encode(data, forKey: .data)
            try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case .opaque:
            break
        }
    }
}

/// The time-to-live for an Anthropic prompt-caching breakpoint.
public enum CacheControlTTL: String, Sendable, Equatable, Codable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
}

struct CacheControl: Encodable {
    let type = "ephemeral"
    let ttl: CacheControlTTL?

    init(ttl: CacheControlTTL? = nil) {
        self.ttl = ttl
    }

    private enum CodingKeys: String, CodingKey {
        case type, ttl
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(ttl, forKey: .ttl)
    }
}

struct AnthropicSystemBlock: Encodable {
    let type = "text"
    let text: String
    var cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }
}

struct AnthropicToolDefinition: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let strict: Bool?
    var cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case name, description, strict
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
    }

    init(_ definition: ToolDefinition) {
        name = definition.name
        description = definition.description
        inputSchema = definition.parametersSchema
        strict = definition.strict
    }
}

/// How Anthropic should select a tool on the next turn.
public enum AnthropicToolChoice: Sendable, Equatable {
    case auto(disableParallel: Bool = false)
    case any(disableParallel: Bool = false)
    case tool(name: String, disableParallel: Bool = false)
    case none
}

extension AnthropicToolChoice: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, name
        case disableParallelToolUse = "disable_parallel_tool_use"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .auto(disable):
            try container.encode("auto", forKey: .type)
            if disable { try container.encode(true, forKey: .disableParallelToolUse) }
        case let .any(disable):
            try container.encode("any", forKey: .type)
            if disable { try container.encode(true, forKey: .disableParallelToolUse) }
        case let .tool(name, disable):
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
            if disable { try container.encode(true, forKey: .disableParallelToolUse) }
        case .none:
            try container.encode("none", forKey: .type)
        }
    }
}

struct AnthropicResponse: Decodable {
    let content: [AnthropicResponseBlock]
    let usage: AnthropicUsage
}

enum AnthropicResponseBlock: Decodable {
    case text(String)
    case thinking(thinking: String, signature: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case opaque(OpaqueResponseItem)

    private enum ResponseBlockType: String {
        case text, thinking
        case toolUse = "tool_use"
    }

    private enum TypeKey: String, CodingKey { case type }
    private enum TextKeys: String, CodingKey { case text }
    private enum ThinkingKeys: String, CodingKey { case thinking, signature }
    private enum ToolUseKeys: String, CodingKey { case id, name, input }

    init(from decoder: any Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TypeKey.self)
        let typeString = try typeContainer.decode(String.self, forKey: .type)
        guard let blockType = ResponseBlockType(rawValue: typeString) else {
            let raw = try JSONValue(from: decoder)
            self = .opaque(OpaqueResponseItem(provider: "anthropic", type: typeString, raw: raw))
            return
        }
        switch blockType {
        case .text:
            let container = try decoder.container(keyedBy: TextKeys.self)
            self = try .text(container.decode(String.self, forKey: .text))
        case .thinking:
            let container = try decoder.container(keyedBy: ThinkingKeys.self)
            let thinking = try container.decode(String.self, forKey: .thinking)
            let signature = try container.decode(String.self, forKey: .signature)
            self = .thinking(thinking: thinking, signature: signature)
        case .toolUse:
            let container = try decoder.container(keyedBy: ToolUseKeys.self)
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode(JSONValue.self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)
        }
    }
}

struct AnthropicUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

struct AnthropicErrorResponse: Decodable {
    let type: String
    let error: AnthropicErrorDetail
}

struct AnthropicErrorDetail: Decodable {
    let type: String
    let message: String
}

enum AnthropicMessageMapper {
    static func mapMessages(
        _ messages: [ChatMessage]
    ) throws -> (system: [AnthropicSystemBlock]?, messages: [AnthropicMessage]) {
        var systemBlocks: [AnthropicSystemBlock] = []
        var anthropicMessages: [AnthropicMessage] = []

        var pendingToolResults: [AnthropicContentBlock] = []

        for message in messages {
            switch message {
            case let .system(text):
                systemBlocks.append(AnthropicSystemBlock(text: text))

            case let .user(text):
                flushToolResults(&pendingToolResults, into: &anthropicMessages)
                anthropicMessages.append(AnthropicMessage(
                    role: .user, content: .text(text)
                ))

            case let .userMultimodal(parts):
                flushToolResults(&pendingToolResults, into: &anthropicMessages)
                let blocks = try parts.map(Self.anthropicBlock(for:))
                anthropicMessages.append(AnthropicMessage(role: .user, content: .blocks(blocks)))

            case let .assistant(msg):
                flushToolResults(&pendingToolResults, into: &anthropicMessages)
                try anthropicMessages.append(mapAssistantMessage(msg))

            case let .tool(id, _, content):
                pendingToolResults.append(.toolResult(
                    toolUseId: id, content: content, isError: false
                ))
            }
        }

        flushToolResults(&pendingToolResults, into: &anthropicMessages)

        return (
            system: systemBlocks.isEmpty ? nil : systemBlocks,
            messages: anthropicMessages
        )
    }

    private static func flushToolResults(
        _ pending: inout [AnthropicContentBlock],
        into messages: inout [AnthropicMessage]
    ) {
        guard !pending.isEmpty else { return }
        messages.append(AnthropicMessage(role: .user, content: .blocks(pending)))
        pending = []
    }

    private static func mapAssistantMessage(
        _ msg: AssistantMessage
    ) throws -> AnthropicMessage {
        if let continuity = msg.continuity, continuity.substrate == .anthropicMessages {
            let blocks = try AnthropicTurnProjection.replayBlocks(from: continuity)
            return AnthropicMessage(role: .assistant, content: .blocks(blocks))
        }

        var blocks: [AnthropicContentBlock] = []

        if let details = msg.reasoningDetails {
            for detail in details {
                if case let .object(dict) = detail,
                   case let .string(thinking) = dict["thinking"],
                   case let .string(signature) = dict["signature"] {
                    blocks.append(.thinking(thinking: thinking, signature: signature))
                }
            }
        } else if let reasoning = msg.reasoning, let signature = reasoning.signature {
            blocks.append(.thinking(thinking: reasoning.content, signature: signature))
        }

        if !msg.content.isEmpty {
            blocks.append(.text(msg.content))
        }

        for call in msg.toolCalls {
            let input = try parseToolCallInput(call.arguments)
            blocks.append(.toolUse(id: call.id, name: call.name, input: input))
        }

        if blocks.isEmpty {
            blocks.append(.text(""))
        }

        return AnthropicMessage(role: .assistant, content: .blocks(blocks))
    }

    static func anthropicBlock(for part: ContentPart) throws -> AnthropicContentBlock {
        switch part {
        case let .text(text):
            return .text(text)
        case .imageURL:
            throw AgentError.llmError(.featureUnsupported(
                provider: "anthropic", feature: "image URL (use base64 data instead)"
            ))
        case let .imageBase64(data, mimeType):
            return .image(mediaType: mimeType, data: data.base64EncodedString())
        case let .videoBase64(_, mimeType):
            throw AgentError.llmError(.featureUnsupported(
                provider: "anthropic", feature: "video (\(mimeType))"
            ))
        case let .pdfBase64(data):
            return .document(mediaType: "application/pdf", data: data.base64EncodedString())
        case let .audioBase64(_, format):
            throw AgentError.llmError(.featureUnsupported(
                provider: "anthropic", feature: "audio (\(format.rawValue))"
            ))
        }
    }

    private static func parseToolCallInput(_ arguments: String) throws -> JSONValue {
        let data = Data(arguments.utf8)
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AgentError.llmError(.decodingFailed(
                description: "Failed to parse tool call arguments as JSON: \(arguments)"
            ))
        }
    }
}
