import AgentRunKit
import Foundation

/// A schema-walking LLM client that auto-generates valid tool call arguments for offline testing.
public struct TestLLMClient: LLMClient, Sendable {
    /// Controls which tools the client calls on each turn.
    public enum CallToolsMode: Sendable, Equatable {
        case all
        case specific([String])
    }

    public let seed: Int
    public let callTools: CallToolsMode
    public let finishContent: String
    public let contextWindowSize: Int?
    public let providerIdentifier: ProviderIdentifier = .custom("test")
    public let tokenUsage: TokenUsage

    public init(
        seed: Int = 0,
        callTools: CallToolsMode = .all,
        finishContent: String = "Test completed",
        contextWindowSize: Int? = nil,
        tokenUsage: TokenUsage = TokenUsage(input: 1, output: 1)
    ) {
        self.seed = seed
        self.callTools = callTools
        self.finishContent = finishContent
        self.contextWindowSize = contextWindowSize
        self.tokenUsage = tokenUsage
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        let response = buildResponse(messages: messages, tools: tools, responseFormat: responseFormat)
        return AssistantMessage(
            content: response.content,
            toolCalls: response.toolCalls,
            tokenUsage: tokenUsage
        )
    }

    public func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let response = buildResponse(messages: messages, tools: tools, responseFormat: nil)
        return AsyncThrowingStream { continuation in
            if !response.content.isEmpty {
                continuation.yield(.content(response.content))
            }
            for (index, call) in response.toolCalls.enumerated() {
                continuation.yield(.toolCallStart(index: index, id: call.id, name: call.name, kind: call.kind))
                continuation.yield(.toolCallDelta(index: index, arguments: call.arguments))
            }
            continuation.yield(.finished(usage: tokenUsage))
            continuation.finish()
        }
    }
}

private extension TestLLMClient {
    struct Response {
        let toolCalls: [ToolCall]
        let content: String
    }

    func buildResponse(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?
    ) -> Response {
        if let responseFormat {
            let json = SchemaWalker.generateJSON(from: responseFormat.schema, seed: seed)
            return Response(toolCalls: [], content: json)
        }

        let reservedFinishTool = tools.first(where: isReservedFinishTool)
        let selectableTools = tools.filter { !isReservedTool($0) && toolMatchesMode($0) }

        if hasToolResultsAfterLastUserMessage(messages) || selectableTools.isEmpty {
            if reservedFinishTool != nil {
                return Response(toolCalls: buildFinishToolCalls(), content: "")
            }
            return Response(toolCalls: [], content: finishContent)
        }

        let toolCalls = selectableTools.enumerated().map { index, tool in
            ToolCall(
                id: "test_call_\(index)",
                name: tool.name,
                arguments: SchemaWalker.generateJSON(from: tool.parametersSchema, seed: seed &+ index)
            )
        }
        return Response(toolCalls: toolCalls, content: "")
    }

    func buildFinishToolCalls() -> [ToolCall] {
        let arguments = encodeJSON(FinishArguments(content: finishContent, reason: nil))
        return [ToolCall(id: "test_finish", name: reservedFinishToolDefinition.name, arguments: arguments)]
    }

    func toolMatchesMode(_ tool: ToolDefinition) -> Bool {
        switch callTools {
        case .all:
            true
        case let .specific(names):
            names.contains(tool.name)
        }
    }

    func hasToolResultsAfterLastUserMessage(_ messages: [ChatMessage]) -> Bool {
        guard let lastUserIndex = messages.lastIndex(where: {
            if case .user = $0 { return true }
            if case .userMultimodal = $0 { return true }
            return false
        }) else {
            return false
        }
        return messages[lastUserIndex...].contains {
            if case .tool = $0 { return true }
            return false
        }
    }

    func isReservedFinishTool(_ tool: ToolDefinition) -> Bool {
        tool == reservedFinishToolDefinition
    }

    func isReservedPruneTool(_ tool: ToolDefinition) -> Bool {
        tool == reservedPruneContextToolDefinition
    }

    func isReservedTool(_ tool: ToolDefinition) -> Bool {
        isReservedFinishTool(tool) || isReservedPruneTool(tool)
    }
}

private enum SchemaWalker {
    static func generateJSON(from schema: JSONSchema, seed: Int) -> String {
        encodeJSON(generateValue(from: schema, seed: seed))
    }

    static func generateValue(from schema: JSONSchema, seed: Int) -> SyntheticJSONValue {
        switch schema {
        case let .string(_, enumValues):
            if let enumValues, !enumValues.isEmpty {
                return .string(enumValues[safeModulo(seed, enumValues.count)])
            }
            return .string("test_\(seed)")
        case .integer:
            return .int(seed)
        case .number:
            return .double(Double(seed) + 0.5)
        case .boolean:
            return .bool(seed.isMultiple(of: 2))
        case .null:
            return .null
        case let .array(items, _):
            return .array([generateValue(from: items, seed: seed)])
        case let .object(properties, _, _):
            let sortedProperties = properties.sorted { $0.key < $1.key }
            guard !sortedProperties.isEmpty else { return .object([:]) }

            var object: [String: SyntheticJSONValue] = [:]
            for (index, entry) in sortedProperties.enumerated() {
                object[entry.key] = generateValue(from: entry.value, seed: seed &+ index)
            }
            return .object(object)
        case let .anyOf(schemas):
            let nonNullSchemas = schemas.filter {
                if case .null = $0 { return false }
                return true
            }
            guard !nonNullSchemas.isEmpty else { return .null }
            return generateValue(from: nonNullSchemas[safeModulo(seed, nonNullSchemas.count)], seed: seed)
        }
    }
}

private indirect enum SyntheticJSONValue: Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([SyntheticJSONValue])
    case object([String: SyntheticJSONValue])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case let .array(values):
            try container.encode(values)
        case let .object(values):
            try container.encode(values)
        }
    }
}

private func safeModulo(_ value: Int, _ divisor: Int) -> Int {
    let remainder = value % divisor
    return remainder < 0 ? remainder + divisor : remainder
}

private func encodeJSON(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data: Data
    do {
        data = try encoder.encode(value)
    } catch {
        preconditionFailure("JSON encoding failed: \(error)")
    }
    guard let json = String(data: data, encoding: .utf8) else {
        preconditionFailure("JSONEncoder produced invalid UTF-8")
    }
    return json
}
