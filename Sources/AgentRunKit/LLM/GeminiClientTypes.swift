import Foundation

struct GeminiRequest: Encodable, Sendable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiContent?
    let tools: [GeminiTool]?
    let toolConfig: GeminiToolConfig?
    let generationConfig: GeminiGenerationConfig?
    let extraFields: [String: JSONValue]

    private static let validExtraFields: Set<String> = [
        "temperature", "top_p", "top_k", "stop_sequences",
        "safety_settings", "cached_content"
    ]

    enum CodingKeys: String, CodingKey {
        case contents, tools
        case systemInstruction = "system_instruction"
        case toolConfig = "tool_config"
        case generationConfig = "generation_config"
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

// MARK: - Content & Parts

struct GeminiContent: Codable, Sendable {
    let role: String?
    let parts: [GeminiPart]
}

struct GeminiPart: Codable, Sendable {
    let text: String?
    let functionCall: GeminiFunctionCall?
    let functionResponse: GeminiFunctionResponse?
    let thought: Bool?
    let thoughtSignature: String?

    enum CodingKeys: String, CodingKey {
        case text
        case functionCall = "functionCall"
        case functionResponse = "functionResponse"
        case thought
        case thoughtSignature
    }

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

struct GeminiFunctionCall: Codable, Sendable {
    let id: String?
    let name: String
    let args: JSONValue?
}

struct GeminiFunctionResponse: Codable, Sendable {
    let id: String?
    let name: String
    let response: JSONValue

    enum CodingKeys: String, CodingKey {
        case id, name, response
    }
}

// MARK: - Tool Definitions

struct GeminiTool: Encodable, Sendable {
    let functionDeclarations: [GeminiFunctionDeclaration]?

    enum CodingKeys: String, CodingKey {
        case functionDeclarations = "function_declarations"
    }
}

struct GeminiFunctionDeclaration: Encodable, Sendable {
    let name: String
    let description: String
    let parametersJsonSchema: JSONSchema

    enum CodingKeys: String, CodingKey {
        case name, description
        case parametersJsonSchema = "parameters"
    }

    init(_ definition: ToolDefinition) {
        name = definition.name
        description = definition.description
        parametersJsonSchema = definition.parametersSchema
    }
}

struct GeminiToolConfig: Encodable, Sendable {
    let functionCallingConfig: GeminiFunctionCallingConfig?

    enum CodingKeys: String, CodingKey {
        case functionCallingConfig = "function_calling_config"
    }
}

struct GeminiFunctionCallingConfig: Encodable, Sendable {
    let mode: String

    init(mode: String = "AUTO") {
        self.mode = mode
    }
}

// MARK: - Generation Config

struct GeminiGenerationConfig: Encodable, Sendable {
    let maxOutputTokens: Int?
    let thinkingConfig: GeminiThinkingConfig?
    let responseMimeType: String?
    let responseJsonSchema: JSONSchema?

    enum CodingKeys: String, CodingKey {
        case maxOutputTokens = "maxOutputTokens"
        case thinkingConfig = "thinkingConfig"
        case responseMimeType = "responseMimeType"
        case responseJsonSchema = "responseJsonSchema"
    }

    init(
        maxOutputTokens: Int? = nil,
        thinkingConfig: GeminiThinkingConfig? = nil,
        responseMimeType: String? = nil,
        responseJsonSchema: JSONSchema? = nil
    ) {
        self.maxOutputTokens = maxOutputTokens
        self.thinkingConfig = thinkingConfig
        self.responseMimeType = responseMimeType
        self.responseJsonSchema = responseJsonSchema
    }
}

struct GeminiThinkingConfig: Encodable, Sendable {
    let includeThoughts: Bool
    let thinkingBudget: Int?
    let thinkingLevel: String?

    enum CodingKeys: String, CodingKey {
        case includeThoughts = "includeThoughts"
        case thinkingBudget = "thinkingBudget"
        case thinkingLevel = "thinkingLevel"
    }
}

// MARK: - Response Types

struct GeminiResponse: Decodable, Sendable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?
}

struct GeminiCandidate: Decodable, Sendable {
    let content: GeminiContent?
    let finishReason: String?
}

struct GeminiUsageMetadata: Decodable, Sendable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let thoughtsTokenCount: Int?
    let cachedContentTokenCount: Int?
}

struct GeminiErrorResponse: Decodable, Sendable {
    let error: GeminiErrorDetail
}

struct GeminiErrorDetail: Decodable, Sendable {
    let code: Int
    let message: String
    let status: String
}

// MARK: - Message Mapper

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
                let responseValue: JSONValue
                if let data = content.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    responseValue = parsed
                } else {
                    responseValue = .object(["result": .string(content)])
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
