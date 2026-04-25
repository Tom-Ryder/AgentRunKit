import Foundation

/// A structured output schema routed through Anthropic's `output_config.format` field.
public struct AnthropicJSONOutputFormat: Sendable, Equatable, Encodable {
    public let schema: JSONSchema
    let type = "json_schema"

    public init(schema: JSONSchema) {
        self.schema = schema
    }

    private enum CodingKeys: String, CodingKey {
        case type, schema
    }
}

/// How adaptive thinking content appears in the response.
public enum AnthropicThinkingDisplay: String, Sendable, Equatable, Encodable {
    case summarized
    case omitted
}

enum AnthropicThinkingConfig: Encodable {
    case enabled(budgetTokens: Int)
    case adaptive(display: AnthropicThinkingDisplay?)
    case disabled

    var budgetTokens: Int? {
        switch self {
        case let .enabled(tokens): tokens
        case .adaptive, .disabled: nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, display
        case budgetTokens = "budget_tokens"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .enabled(budgetTokens):
            try container.encode("enabled", forKey: .type)
            try container.encode(budgetTokens, forKey: .budgetTokens)
        case let .adaptive(display):
            try container.encode("adaptive", forKey: .type)
            try container.encodeIfPresent(display, forKey: .display)
        case .disabled:
            try container.encode("disabled", forKey: .type)
        }
    }
}

struct AnthropicOutputConfig: Encodable {
    let effort: AnthropicOutputEffort?
    let format: AnthropicJSONOutputFormat?

    init(effort: AnthropicOutputEffort? = nil, format: AnthropicJSONOutputFormat? = nil) {
        self.effort = effort
        self.format = format
    }
}

enum AnthropicOutputEffort: String, Encodable {
    case low, medium, high, max
}
