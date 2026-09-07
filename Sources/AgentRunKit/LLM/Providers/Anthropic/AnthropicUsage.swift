import Foundation

struct AnthropicUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    let outputTokensDetails: AnthropicOutputTokensDetails?

    var tokenUsage: TokenUsage? {
        Self.normalizedTokenUsage(
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens, cacheCreationInputTokens: cacheCreationInputTokens,
            thinkingTokens: outputTokensDetails?.thinkingTokens
        )
    }

    static func normalizedTokenUsage(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadInputTokens: Int?,
        cacheCreationInputTokens: Int?,
        thinkingTokens: Int?
    ) -> TokenUsage? {
        let (cachedInput, readOverflow) = inputTokens.addingReportingOverflow(cacheReadInputTokens ?? 0)
        let (input, writeOverflow) = cachedInput.addingReportingOverflow(cacheCreationInputTokens ?? 0)
        let reasoning = thinkingTokens ?? 0
        guard !readOverflow, !writeOverflow, reasoning <= outputTokens else { return nil }
        return TokenUsage(
            input: input, output: outputTokens - reasoning, reasoning: reasoning,
            cacheRead: cacheReadInputTokens, cacheWrite: cacheCreationInputTokens
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeTokenCount(forKey: .inputTokens)
        outputTokens = try container.decodeTokenCount(forKey: .outputTokens)
        cacheCreationInputTokens = try container.decodeTokenCountIfPresent(forKey: .cacheCreationInputTokens)
        cacheReadInputTokens = try container.decodeTokenCountIfPresent(forKey: .cacheReadInputTokens)
        outputTokensDetails = try container.decodeIfPresent(
            AnthropicOutputTokensDetails.self, forKey: .outputTokensDetails
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokensDetails = "output_tokens_details"
    }
}

struct AnthropicOutputTokensDetails: Decodable {
    let thinkingTokens: Int

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thinkingTokens = try container.decodeTokenCount(forKey: .thinkingTokens)
    }

    private enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }
}

struct AnthropicDeltaUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    let outputTokensDetails: AnthropicOutputTokensDetails?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeTokenCountIfPresent(forKey: .inputTokens)
        outputTokens = try container.decodeTokenCount(forKey: .outputTokens)
        cacheCreationInputTokens = try container.decodeTokenCountIfPresent(forKey: .cacheCreationInputTokens)
        cacheReadInputTokens = try container.decodeTokenCountIfPresent(forKey: .cacheReadInputTokens)
        outputTokensDetails = try container.decodeIfPresent(
            AnthropicOutputTokensDetails.self, forKey: .outputTokensDetails
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokensDetails = "output_tokens_details"
    }
}
