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
    private static let generationConfigExtraFields: Set<String> = [
        "temperature", "topP", "topK", "stopSequences"
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

        if !extraFields.isEmpty {
            try ProviderExtraFields.validateAllowedKeys(
                extraFields,
                allowedKeys: Self.validExtraFields,
                debugDescriptionPrefix: "Invalid extraFields for Gemini API: ",
                codingPath: encoder.codingPath
            )

            let generationExtraFields = extraFields.filter { key, _ in
                Self.generationConfigExtraFields.contains(key)
            }
            let rootExtraFields = extraFields.filter { key, _ in
                !Self.generationConfigExtraFields.contains(key)
            }

            let mergedGenerationConfig: GeminiGenerationConfig? = {
                guard generationConfig != nil || !generationExtraFields.isEmpty else { return nil }
                return GeminiGenerationConfig(
                    maxOutputTokens: generationConfig?.maxOutputTokens,
                    thinkingConfig: generationConfig?.thinkingConfig,
                    responseMimeType: generationConfig?.responseMimeType,
                    responseSchema: generationConfig?.responseSchema,
                    responseJsonSchema: generationConfig?.responseJsonSchema,
                    extraFields: generationExtraFields
                )
            }()
            try container.encodeIfPresent(mergedGenerationConfig, forKey: .generationConfig)

            try ProviderExtraFields.encode(rootExtraFields, to: encoder)
            return
        }

        try container.encodeIfPresent(generationConfig, forKey: .generationConfig)
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
    let inlineData: GeminiInlineData?

    init(
        text: String? = nil,
        functionCall: GeminiFunctionCall? = nil,
        functionResponse: GeminiFunctionResponse? = nil,
        thought: Bool? = nil,
        thoughtSignature: String? = nil,
        inlineData: GeminiInlineData? = nil
    ) {
        self.text = text
        self.functionCall = functionCall
        self.functionResponse = functionResponse
        self.thought = thought
        self.thoughtSignature = thoughtSignature
        self.inlineData = inlineData
    }
}

struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String
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

    init(_ definition: ToolDefinition) throws {
        if definition.strict == true {
            throw AgentError.llmError(.featureUnsupported(
                provider: "gemini",
                feature: "strict function schemas"
            ))
        }
        name = definition.name
        description = definition.description
        parametersJsonSchema = GeminiSchema(definition.parametersSchema)
    }
}

struct GeminiToolConfig: Encodable {
    let functionCallingConfig: GeminiFunctionCallingConfig?
}

/// Routing behavior for Gemini function calling.
public enum GeminiFunctionCallingMode: String, Sendable, Equatable {
    case auto = "AUTO"
    case any = "ANY"
    case none = "NONE"
    case validated = "VALIDATED"
}

struct GeminiFunctionCallingConfig: Encodable {
    let mode: String
    let allowedFunctionNames: [String]?

    init(mode: GeminiFunctionCallingMode = .auto, allowedFunctionNames: [String]? = nil) {
        self.mode = mode.rawValue
        self.allowedFunctionNames = allowedFunctionNames
    }
}

struct GeminiGenerationConfig: Encodable {
    let maxOutputTokens: Int?
    let thinkingConfig: GeminiThinkingConfig?
    let responseMimeType: String?
    let responseSchema: GeminiSchema?
    let responseJsonSchema: GeminiSchema?
    let extraFields: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case maxOutputTokens
        case thinkingConfig, responseMimeType, responseSchema, responseJsonSchema
    }

    init(
        maxOutputTokens: Int? = nil,
        thinkingConfig: GeminiThinkingConfig? = nil,
        responseMimeType: String? = nil,
        responseSchema: GeminiSchema? = nil,
        responseJsonSchema: GeminiSchema? = nil,
        extraFields: [String: JSONValue] = [:]
    ) {
        self.maxOutputTokens = maxOutputTokens
        self.thinkingConfig = thinkingConfig
        self.responseMimeType = responseMimeType
        self.responseSchema = responseSchema
        self.responseJsonSchema = responseJsonSchema
        self.extraFields = extraFields
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encodeIfPresent(thinkingConfig, forKey: .thinkingConfig)
        try container.encodeIfPresent(responseMimeType, forKey: .responseMimeType)
        try container.encodeIfPresent(responseSchema, forKey: .responseSchema)
        try container.encodeIfPresent(responseJsonSchema, forKey: .responseJsonSchema)

        if !extraFields.isEmpty {
            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in extraFields {
                try dynamicContainer.encode(value, forKey: DynamicCodingKey(key))
            }
        }
    }
}

struct GeminiThinkingConfig: Encodable {
    let includeThoughts: Bool
    let thinkingBudget: Int?
    let thinkingLevel: String?
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
        TokenUsage(
            input: promptTokenCount ?? 0,
            output: candidatesTokenCount ?? 0,
            reasoning: thoughtsTokenCount ?? 0,
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

enum GeminiReasoningDetail {
    private static let functionCallSignatureType = "gemini.function_call"

    static func functionCallSignature(
        toolCallID: String,
        signature: String
    ) -> JSONValue {
        .object([
            "type": .string(functionCallSignatureType),
            "tool_call_id": .string(toolCallID),
            "thought_signature": .string(signature)
        ])
    }

    static func functionCallSignatures(
        from details: [JSONValue]
    ) -> [String: String] {
        var signatures: [String: String] = [:]
        for detail in details {
            guard case let .object(dict) = detail,
                  case .string(functionCallSignatureType) = dict["type"],
                  case let .string(toolCallID) = dict["tool_call_id"],
                  case let .string(signature) = dict["thought_signature"]
            else {
                continue
            }
            signatures[toolCallID] = signature
        }
        return signatures
    }
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

            case let .userMultimodal(parts):
                flushFunctionResponses(&pendingFunctionResponses, into: &contents)
                let geminiParts = try parts.map(Self.geminiPart(for:))
                contents.append(GeminiContent(role: "user", parts: geminiParts))

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
        let functionCallSignatures = GeminiReasoningDetail.functionCallSignatures(
            from: msg.reasoningDetails ?? []
        )

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
                ),
                thoughtSignature: functionCallSignatures[call.id]
            ))
        }

        if parts.isEmpty {
            parts.append(GeminiPart(text: ""))
        }

        return GeminiContent(role: "model", parts: parts)
    }

    static func geminiPart(for part: ContentPart) throws -> GeminiPart {
        switch part {
        case let .text(text):
            return GeminiPart(text: text)
        case .imageURL:
            throw AgentError.llmError(.featureUnsupported(
                provider: "gemini", feature: "image URL (use inline base64 data instead)"
            ))
        case let .imageBase64(data, mimeType):
            return GeminiPart(inlineData: GeminiInlineData(
                mimeType: mimeType, data: data.base64EncodedString()
            ))
        case let .videoBase64(data, mimeType):
            return GeminiPart(inlineData: GeminiInlineData(
                mimeType: mimeType, data: data.base64EncodedString()
            ))
        case let .pdfBase64(data):
            return GeminiPart(inlineData: GeminiInlineData(
                mimeType: "application/pdf", data: data.base64EncodedString()
            ))
        case let .audioBase64(data, format):
            return GeminiPart(inlineData: GeminiInlineData(
                mimeType: format.mimeType, data: data.base64EncodedString()
            ))
        }
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
