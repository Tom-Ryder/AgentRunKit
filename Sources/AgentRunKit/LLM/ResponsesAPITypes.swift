import Foundation

struct ResponsesRequest: Encodable {
    let model: String?
    let instructions: String?
    let input: [ResponsesInputItem]
    let tools: [ResponsesToolDefinition]?
    let stream: Bool?
    let maxOutputTokens: Int?
    let text: ResponsesTextConfig?
    let store: Bool
    let reasoning: ResponsesReasoningConfig?
    let include: [String]?
    let previousResponseId: String?
    let extraFields: [String: JSONValue]

    private static let validExtraFields: Set<String> = [
        "temperature", "top_p", "metadata", "truncation",
        "user", "service_tier", "tool_choice", "parallel_tool_calls"
    ]

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, tools, stream, text, store, reasoning, include
        case maxOutputTokens = "max_output_tokens"
        case previousResponseId = "previous_response_id"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encode(input, forKey: .input)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(stream, forKey: .stream)
        try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encode(store, forKey: .store)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(include, forKey: .include)
        try container.encodeIfPresent(previousResponseId, forKey: .previousResponseId)

        if !extraFields.isEmpty {
            let invalidKeys = extraFields.keys.filter { !Self.validExtraFields.contains($0) }
            if !invalidKeys.isEmpty {
                throw EncodingError.invalidValue(
                    extraFields,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Invalid extraFields for Responses API: "
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

enum ResponsesInputItem: Encodable {
    case userMessage(role: String, content: String)
    case assistantMessage(ResponsesAssistantItem)
    case functionCall(ResponsesFunctionCallItem)
    case functionCallOutput(ResponsesFunctionCallOutputItem)
    case reasoning(JSONValue)
    case raw(JSONValue)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case let .userMessage(role, content):
            var container = encoder.container(keyedBy: UserMessageKeys.self)
            try container.encode("message", forKey: .type)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case let .assistantMessage(item):
            try item.encode(to: encoder)
        case let .functionCall(item):
            try item.encode(to: encoder)
        case let .functionCallOutput(item):
            try item.encode(to: encoder)
        case let .reasoning(value):
            try value.encode(to: encoder)
        case let .raw(value):
            try value.encode(to: encoder)
        }
    }

    private enum UserMessageKeys: String, CodingKey {
        case type, role, content
    }
}

struct ResponsesAssistantItem: Encodable {
    let type = "message"
    let role = "assistant"
    let content: [ResponsesOutputTextItem]

    enum CodingKeys: String, CodingKey {
        case type, role, content
    }
}

struct ResponsesOutputTextItem: Encodable {
    let type = "output_text"
    let text: String

    enum CodingKeys: String, CodingKey {
        case type, text
    }
}

struct ResponsesFunctionCallItem: Encodable {
    let type = "function_call"
    let callId: String
    let name: String
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case name, arguments
    }
}

struct ResponsesFunctionCallOutputItem: Encodable {
    let type = "function_call_output"
    let callId: String
    let output: String

    enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case output
    }
}

struct ResponsesToolDefinition: Encodable {
    let type = "function"
    let name: String
    let description: String
    let parameters: JSONSchema

    enum CodingKeys: String, CodingKey {
        case type, name, description, parameters
    }

    init(_ definition: ToolDefinition) {
        name = definition.name
        description = definition.description
        parameters = definition.parametersSchema
    }
}

struct ResponsesTextConfig: Encodable {
    let format: ResponsesFormatConfig
}

struct ResponsesFormatConfig: Encodable {
    let type = "json_schema"
    let name: String
    let strict = true
    let schema: JSONSchema

    enum CodingKeys: String, CodingKey {
        case type, name, strict, schema
    }
}

struct ResponsesReasoningConfig: Encodable {
    let effort: String
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case effort, summary
    }

    init(_ config: ReasoningConfig) {
        effort = config.effort.rawValue
        summary = config.exclude == true ? "disabled" : "auto"
    }
}

struct ResponsesAPIResponse: Decodable {
    let id: String
    let status: String?
    let output: [ResponsesOutputItem]
    let usage: ResponsesUsage?
    let error: ResponsesErrorDetail?

    private enum CodingKeys: String, CodingKey {
        case id, status, output, usage, error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        output = try container.decode([JSONValue].self, forKey: .output)
            .map(ResponsesOutputItem.init)
        usage = try container.decodeIfPresent(ResponsesUsage.self, forKey: .usage)
        error = try container.decodeIfPresent(ResponsesErrorDetail.self, forKey: .error)
    }
}

enum ResponsesOutputItem {
    case message(ResponsesMessageOutput)
    case functionCall(ResponsesFunctionCallOutput)
    case reasoning(ResponsesReasoningOutput)
    case opaque(JSONValue)

    init(_ raw: JSONValue) throws {
        let type = try raw.requiredType()
        switch type {
        case "message":
            self = try .message(ResponsesMessageOutput(raw: raw))
        case "function_call":
            self = try .functionCall(ResponsesFunctionCallOutput(raw: raw))
        case "reasoning":
            self = .reasoning(ResponsesReasoningOutput(raw: raw))
        default:
            self = .opaque(raw)
        }
    }
}

struct ResponsesMessageOutput {
    let replayRaw: JSONValue
    let content: [ResponsesOutputContent]

    init(raw: JSONValue) throws {
        if let roleValue = raw.objectValue?["role"] {
            guard case let .string(role) = roleValue else {
                throw AgentError.llmError(
                    .decodingFailed(description: "Responses message output field 'role' must be a string")
                )
            }
            if role != "assistant" {
                throw AgentError.llmError(
                    .decodingFailed(description: "Responses message output has unsupported role '\(role)'")
                )
            }
        }
        replayRaw = raw.withStringValue("assistant", forKey: "role")
        content = try raw.requiredArrayValue(forKey: "content").map(ResponsesOutputContent.init)
    }
}

struct ResponsesOutputContent {
    let type: String
    let text: String?

    init(_ raw: JSONValue) throws {
        type = try raw.requiredStringValue(forKey: "type")
        if let textValue = raw.objectValue?["text"] {
            guard case let .string(text) = textValue else {
                throw AgentError.llmError(
                    .decodingFailed(description: "Responses output content field 'text' must be a string")
                )
            }
            self.text = text
            return
        }
        if type == "output_text" {
            throw AgentError.llmError(
                .decodingFailed(description: "Responses payload missing string field 'text'")
            )
        }
        text = nil
    }
}

struct ResponsesFunctionCallOutput {
    let raw: JSONValue
    let callId: String
    let name: String
    let arguments: String

    init(raw: JSONValue) throws {
        self.raw = raw
        callId = try raw.requiredStringValue(forKey: "call_id")
        name = try raw.requiredStringValue(forKey: "name")
        arguments = try raw.requiredStringValue(forKey: "arguments")
    }
}

struct ResponsesReasoningOutput {
    let raw: JSONValue
}

struct ResponsesReplayState: Equatable {
    let output: [ResponsesReplayItem]

    init(response: ResponsesAPIResponse) {
        output = response.output.compactMap(ResponsesReplayItem.init)
    }

    init(continuity: AssistantContinuity) throws {
        guard continuity.substrate == .responses else {
            throw AgentError.llmError(.other("Responses replay requested for non-Responses continuity"))
        }
        guard case let .object(payload) = continuity.payload else {
            throw AgentError.llmError(.other("Malformed Responses continuity payload"))
        }
        guard case let .array(outputValues) = payload["output"] else {
            throw AgentError.llmError(.other("Malformed Responses continuity payload"))
        }

        output = try outputValues.map(ResponsesReplayItem.init)
        guard !output.isEmpty else {
            throw AgentError.llmError(.other("Malformed Responses continuity payload"))
        }
    }

    var continuity: AssistantContinuity {
        AssistantContinuity(
            substrate: .responses,
            payload: .object([
                "output": .array(output.map(\.raw)),
            ])
        )
    }

    var replayInputItems: [ResponsesInputItem] {
        output.map(\.inputItem)
    }
}

enum ResponsesReplayItem: Equatable {
    case message(JSONValue)
    case functionCall(JSONValue)
    case reasoning(JSONValue)

    init?(_ outputItem: ResponsesOutputItem) {
        switch outputItem {
        case let .message(message):
            self = .message(message.replayRaw)
        case let .functionCall(call):
            self = .functionCall(call.raw)
        case let .reasoning(reasoning):
            self = .reasoning(reasoning.raw)
        case .opaque:
            return nil
        }
    }

    init(_ raw: JSONValue) throws {
        let type = try raw.requiredType()
        switch type {
        case "message":
            let message = try ResponsesMessageOutput(raw: raw)
            self = .message(message.replayRaw)
        case "function_call":
            _ = try ResponsesFunctionCallOutput(raw: raw)
            self = .functionCall(raw)
        case "reasoning":
            self = .reasoning(raw)
        default:
            throw AgentError.llmError(
                .decodingFailed(description: "Unsupported Responses replay item type '\(type)'")
            )
        }
    }

    var raw: JSONValue {
        switch self {
        case let .message(raw), let .functionCall(raw), let .reasoning(raw):
            raw
        }
    }

    var inputItem: ResponsesInputItem {
        .raw(raw)
    }
}

struct ResponsesUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let outputTokensDetails: ResponsesOutputTokensDetails?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case outputTokensDetails = "output_tokens_details"
    }
}

struct ResponsesOutputTokensDetails: Decodable {
    let reasoningTokens: Int?

    enum CodingKeys: String, CodingKey {
        case reasoningTokens = "reasoning_tokens"
    }
}

struct ResponsesErrorDetail: Decodable {
    let message: String
    let code: String
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    func requiredType() throws -> String {
        try requiredStringValue(forKey: "type")
    }

    func requiredStringValue(forKey key: String) throws -> String {
        guard let value = objectValue?[key]?.stringValue else {
            throw AgentError.llmError(.decodingFailed(description: "Responses payload missing string field '\(key)'"))
        }
        return value
    }

    func requiredArrayValue(forKey key: String) throws -> [JSONValue] {
        guard case let .array(value) = objectValue?[key] else {
            throw AgentError.llmError(.decodingFailed(description: "Responses payload missing array field '\(key)'"))
        }
        return value
    }

    func withStringValue(_ value: String, forKey key: String) -> JSONValue {
        guard case let .object(objectValue) = self else {
            return self
        }
        var updated = objectValue
        updated[key] = .string(value)
        return .object(updated)
    }
}

extension ResponsesAPIClient {
    nonisolated func prefixSignature<C: RandomAccessCollection>(
        _ messages: C
    ) -> Data where C.Element == ChatMessage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(Array(messages))
        } catch {
            preconditionFailure("ChatMessage encoding failed during Responses cursor identity generation: \(error)")
        }
    }
}
