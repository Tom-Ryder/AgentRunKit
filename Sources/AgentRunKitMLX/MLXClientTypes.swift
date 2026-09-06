import AgentRunKit
import Foundation
import MLXLMCommon

enum MLXMessageMapper {
    static func mapMessages(_ messages: [ChatMessage]) -> [[String: any Sendable]] {
        messages.map(mapMessage)
    }

    static func mapToolCall(_ call: MLXLMCommon.ToolCall, index: Int) throws -> AgentRunKit.ToolCall {
        let encoded: Data
        do {
            encoded = try encodeDeterministicJSON(call.function.arguments)
        } catch {
            throw AgentError.llmError(.encodingFailed(error))
        }
        guard let arguments = String(data: encoded, encoding: .utf8) else {
            preconditionFailure("JSONEncoder produced invalid UTF-8")
        }
        return AgentRunKit.ToolCall(
            id: "mlx_call_\(index)",
            name: call.function.name,
            arguments: arguments
        )
    }

    static func toolSpec(from definition: ToolDefinition) -> [String: any Sendable] {
        [
            "type": "function" as any Sendable,
            "function": [
                "name": definition.name,
                "description": definition.description,
                "parameters": schemaDict(definition.parametersSchema)
            ] as [String: any Sendable]
        ]
    }

    static func mergeParameters(
        _ base: GenerateParameters,
        extraFields: [String: AgentRunKit.JSONValue]
    ) -> GenerateParameters {
        var params = base
        for (key, value) in extraFields {
            switch key {
            case "temperature":
                if case let .double(val) = value { params.temperature = Float(val) }
                if case let .int(val) = value { params.temperature = Float(val) }
            case "top_p":
                if case let .double(val) = value { params.topP = Float(val) }
                if case let .int(val) = value { params.topP = Float(val) }
            case "max_tokens":
                if case let .int(val) = value { params.maxTokens = val }
            case "repetition_penalty":
                if case let .double(val) = value { params.repetitionPenalty = Float(val) }
                if case let .int(val) = value { params.repetitionPenalty = Float(val) }
            default:
                break
            }
        }
        return params
    }

    private static func mapMessage(_ message: ChatMessage) -> [String: any Sendable] {
        switch message {
        case let .system(content):
            return ["role": "system", "content": content]
        case let .user(content):
            return ["role": "user", "content": content]
        case let .userMultimodal(parts):
            let text = parts.compactMap { part -> String? in
                if case let .text(str) = part { return str }
                return nil
            }.joined(separator: "\n")
            return ["role": "user", "content": text]
        case let .assistant(msg):
            var dict: [String: any Sendable] = ["role": "assistant", "content": msg.content]
            if !msg.toolCalls.isEmpty {
                dict["tool_calls"] = msg.toolCalls.map { call -> [String: any Sendable] in
                    [
                        "id": call.id as any Sendable,
                        "type": "function" as any Sendable,
                        "function": [
                            "name": call.name,
                            "arguments": call.arguments
                        ] as [String: any Sendable]
                    ]
                }
            }
            return dict
        case let .tool(id, name, content):
            return ["role": "tool", "tool_call_id": id, "name": name, "content": content]
        }
    }

    private static func schemaDict(_ schema: JSONSchema) -> [String: any Sendable] {
        switch schema {
        case let .string(description, enumValues):
            stringSchemaDict(description: description, enumValues: enumValues)
        case let .integer(description):
            scalarSchemaDict(type: "integer", description: description)
        case let .number(description):
            scalarSchemaDict(type: "number", description: description)
        case let .boolean(description):
            scalarSchemaDict(type: "boolean", description: description)
        case .null:
            ["type": "null"]
        case let .array(items, description):
            arraySchemaDict(items: items, description: description)
        case let .object(properties, required, description):
            objectSchemaDict(properties: properties, required: required, description: description)
        case let .anyOf(schemas):
            ["anyOf": schemas.map { schemaDict($0) }]
        }
    }

    private static func stringSchemaDict(
        description: String?,
        enumValues: [String]?
    ) -> [String: any Sendable] {
        var dict = scalarSchemaDict(type: "string", description: description)
        if let enumValues {
            dict["enum"] = enumValues
        }
        return dict
    }

    private static func scalarSchemaDict(
        type: String,
        description: String?
    ) -> [String: any Sendable] {
        var dict: [String: any Sendable] = ["type": type]
        if let description {
            dict["description"] = description
        }
        return dict
    }

    private static func arraySchemaDict(
        items: JSONSchema,
        description: String?
    ) -> [String: any Sendable] {
        var dict: [String: any Sendable] = ["type": "array", "items": schemaDict(items)]
        if let description {
            dict["description"] = description
        }
        return dict
    }

    private static func objectSchemaDict(
        properties: [String: JSONSchema],
        required: [String],
        description: String?
    ) -> [String: any Sendable] {
        var dict: [String: any Sendable] = [
            "type": "object",
            "properties": properties.mapValues { schemaDict($0) } as [String: any Sendable],
            "additionalProperties": false
        ]
        if !required.isEmpty {
            dict["required"] = required
        }
        if let description {
            dict["description"] = description
        }
        return dict
    }
}
