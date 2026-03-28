import Foundation

struct GeminiRequest: Encodable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiContent?
    let tools: [GeminiTool]?
    let toolConfig: GeminiToolConfig?
    let generationConfig: GeminiGenerationConfig?
    let extraFields: [String: JSONValue]

    private static let validExtraFields: Set<String> = [
        "temperature", "topP", "topK", "stopSequences",
        "safetySettings", "cachedContent"
    ]

    enum CodingKeys: String, CodingKey {
        case contents, systemInstruction, tools, toolConfig, generationConfig
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contents, forKey: .contents)
        try container.encodeIfPresent(systemInstruction, forKey: .systemInstruction)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolConfig, forKey: .toolConfig)
        try container.encodeIfPresent(generationConfig, forKey: .generationConfig)

        if !extraFields.isEmpty {
            let invalidKeys = extraFields.keys.filter { !Self.validExtraFields.contains($0) }
            if !invalidKeys.isEmpty {
                throw EncodingError.invalidValue(
                    extraFields,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Invalid extraFields for Gemini API: "
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

struct GeminiContent: Codable {
    let role: String?
    let parts: [GeminiPart]

    init(role: String?, parts: [GeminiPart]) {
        self.role = role
        self.parts = parts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        parts = try container.decodeIfPresent([GeminiPart].self, forKey: .parts) ?? []
    }
}

struct GeminiPart: Codable {
    let text: String?
    let functionCall: GeminiFunctionCall?
    let functionResponse: GeminiFunctionResponse?
    let thought: Bool?
    let thoughtSignature: String?

    init(
        text: String? = nil,
        functionCall: GeminiFunctionCall? = nil,
        functionResponse: GeminiFunctionResponse? = nil,
        thought: Bool? = nil,
        thoughtSignature: String? = nil
    ) {
        self.text = text
        self.functionCall = functionCall
        self.functionResponse = functionResponse
        self.thought = thought
        self.thoughtSignature = thoughtSignature
    }
}

struct GeminiFunctionCall: Codable {
    let id: String?
    let name: String
    let args: JSONValue?
}

struct GeminiFunctionResponse: Codable {
    let id: String?
    let name: String
    let response: JSONValue
}

struct GeminiTool: Encodable {
    let functionDeclarations: [GeminiFunctionDeclaration]?
}

struct GeminiFunctionDeclaration: Encodable {
    let name: String
    let description: String
    let parametersJsonSchema: GeminiSchema

    enum CodingKeys: String, CodingKey {
        case name, description
        case parametersJsonSchema = "parameters"
    }

    init(_ definition: ToolDefinition) {
        name = definition.name
        description = definition.description
        parametersJsonSchema = GeminiSchema(definition.parametersSchema)
    }
}

struct GeminiToolConfig: Encodable {
    let functionCallingConfig: GeminiFunctionCallingConfig?
}

struct GeminiFunctionCallingConfig: Encodable {
    let mode: String

    init(mode: String = "AUTO") {
        self.mode = mode
    }
}

struct GeminiGenerationConfig: Encodable {
    let maxOutputTokens: Int?
    let thinkingConfig: GeminiThinkingConfig?
    let responseMimeType: String?
    let responseSchema: GeminiSchema?

    init(
        maxOutputTokens: Int? = nil,
        thinkingConfig: GeminiThinkingConfig? = nil,
        responseMimeType: String? = nil,
        responseSchema: GeminiSchema? = nil
    ) {
        self.maxOutputTokens = maxOutputTokens
        self.thinkingConfig = thinkingConfig
        self.responseMimeType = responseMimeType
        self.responseSchema = responseSchema
    }
}

struct GeminiThinkingConfig: Encodable {
    let includeThoughts: Bool
    let thinkingBudget: Int?
    let thinkingLevel: String?

    private enum CodingKeys: String, CodingKey {
        case includeThoughts, thinkingBudget, thinkingLevel
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(includeThoughts, forKey: .includeThoughts)
        try container.encodeIfPresent(thinkingBudget, forKey: .thinkingBudget)
        try container.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
    }
}

struct GeminiResponse: Decodable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?
}

struct GeminiCandidate: Decodable {
    let content: GeminiContent?
    let finishReason: String?
}

struct GeminiUsageMetadata: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let thoughtsTokenCount: Int?
    let cachedContentTokenCount: Int?

    var tokenUsage: TokenUsage {
        let thoughts = thoughtsTokenCount ?? 0
        let candidates = candidatesTokenCount ?? 0
        return TokenUsage(
            input: promptTokenCount ?? 0,
            output: max(0, candidates - thoughts),
            reasoning: thoughts,
            cacheRead: cachedContentTokenCount
        )
    }
}

struct GeminiErrorResponse: Decodable {
    let error: GeminiErrorDetail
}

struct GeminiErrorDetail: Decodable {
    let code: Int
    let message: String
    let status: String
}

enum GeminiMessageMapper {
    static func mapMessages(
        _ messages: [ChatMessage]
    ) throws -> (systemInstruction: GeminiContent?, contents: [GeminiContent]) {
        var systemParts: [GeminiPart] = []
        var contents: [GeminiContent] = []
        var pendingFunctionResponses: [GeminiPart] = []

        for message in messages {
            switch message {
            case let .system(text):
                systemParts.append(GeminiPart(text: text))

            case let .user(text):
                flushFunctionResponses(&pendingFunctionResponses, into: &contents)
                contents.append(GeminiContent(role: "user", parts: [GeminiPart(text: text)]))

            case .userMultimodal:
                throw AgentError.llmError(.other(
                    "GeminiClient does not support multimodal content"
                ))

            case let .assistant(msg):
                flushFunctionResponses(&pendingFunctionResponses, into: &contents)
                try contents.append(mapAssistantMessage(msg))

            case let .tool(id, name, content):
                let responseValue: JSONValue = if let data = content.data(using: .utf8),
                                                  let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    parsed
                } else {
                    .object(["result": .string(content)])
                }
                pendingFunctionResponses.append(GeminiPart(
                    functionResponse: GeminiFunctionResponse(
                        id: id, name: name, response: responseValue
                    )
                ))
            }
        }

        flushFunctionResponses(&pendingFunctionResponses, into: &contents)

        return (
            systemInstruction: systemParts.isEmpty ? nil : GeminiContent(role: nil, parts: systemParts),
            contents: contents
        )
    }

    private static func flushFunctionResponses(
        _ pending: inout [GeminiPart],
        into contents: inout [GeminiContent]
    ) {
        guard !pending.isEmpty else { return }
        contents.append(GeminiContent(role: "user", parts: pending))
        pending = []
    }

    private static func mapAssistantMessage(
        _ msg: AssistantMessage
    ) throws -> GeminiContent {
        var parts: [GeminiPart] = []

        if let details = msg.reasoningDetails {
            for detail in details {
                if case let .object(dict) = detail,
                   case let .string(thinking) = dict["thinking"] {
                    let signature: String? = {
                        if case let .string(sig) = dict["signature"] { return sig }
                        return nil
                    }()
                    parts.append(GeminiPart(
                        text: thinking, thought: true, thoughtSignature: signature
                    ))
                }
            }
        } else if let reasoning = msg.reasoning {
            parts.append(GeminiPart(
                text: reasoning.content, thought: true, thoughtSignature: reasoning.signature
            ))
        }

        if !msg.content.isEmpty {
            parts.append(GeminiPart(text: msg.content))
        }

        for call in msg.toolCalls {
            let args = try parseToolCallArgs(call.arguments)
            parts.append(GeminiPart(
                functionCall: GeminiFunctionCall(
                    id: call.id, name: call.name, args: args
                )
            ))
        }

        if parts.isEmpty {
            parts.append(GeminiPart(text: ""))
        }

        return GeminiContent(role: "model", parts: parts)
    }

    private static func parseToolCallArgs(_ arguments: String) throws -> JSONValue {
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

struct GeminiSchema: Encodable {
    let wrapped: JSONSchema

    init(_ schema: JSONSchema) {
        wrapped = schema
    }

    private enum CodingKeys: String, CodingKey {
        case type, description, items, properties, required, anyOf
        case `enum`
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch wrapped {
        case let .string(description, enumValues):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(enumValues, forKey: .enum)

        case let .integer(description):
            try container.encode("integer", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .number(description):
            try container.encode("number", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .boolean(description):
            try container.encode("boolean", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .array(items, description):
            try container.encode("array", forKey: .type)
            try container.encode(GeminiSchema(items), forKey: .items)
            try container.encodeIfPresent(description, forKey: .description)

        case let .object(properties, required, description):
            try container.encode("object", forKey: .type)
            try container.encode(
                properties.mapValues { GeminiSchema($0) },
                forKey: .properties
            )
            if !required.isEmpty {
                try container.encode(required, forKey: .required)
            }
            try container.encodeIfPresent(description, forKey: .description)
            // Intentionally omits additionalProperties — unsupported by Gemini API

        case .null:
            try container.encode("null", forKey: .type)

        case let .anyOf(schemas):
            try container.encode(schemas.map { GeminiSchema($0) }, forKey: .anyOf)
        }
    }
}
