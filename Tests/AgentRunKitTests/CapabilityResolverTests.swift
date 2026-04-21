@testable import AgentRunKit
import Foundation
import Testing

// MARK: - Anthropic model family classification

struct AnthropicModelFamilyClassificationTests {
    @Test
    func opus47_prefix() {
        #expect(AnthropicModelFamily.classify("claude-opus-4-7") == .opus47)
        #expect(AnthropicModelFamily.classify("claude-opus-4-7-20260101") == .opus47)
    }

    @Test
    func opus46_prefix() {
        #expect(AnthropicModelFamily.classify("claude-opus-4-6") == .opus46)
        #expect(AnthropicModelFamily.classify("claude-opus-4-6-20251201") == .opus46)
    }

    @Test
    func sonnet46_prefix() {
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-6") == .sonnet46)
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-6-20250929") == .sonnet46)
    }

    @Test
    func haiku45_prefix() {
        #expect(AnthropicModelFamily.classify("claude-haiku-4-5") == .haiku45)
        #expect(AnthropicModelFamily.classify("claude-haiku-4-5-20251001") == .haiku45)
        #expect(AnthropicModelFamily.classify("claude-haiku-4-5@20251001") == .haiku45)
    }

    @Test
    func sonnet45_prefix() {
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-5") == .sonnet45)
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-5-20250929") == .sonnet45)
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-5@20250929") == .sonnet45)
    }

    @Test
    func opus45_prefix() {
        #expect(AnthropicModelFamily.classify("claude-opus-4-5") == .opus45)
        #expect(AnthropicModelFamily.classify("claude-opus-4-5-20251101") == .opus45)
    }

    @Test
    func olderFamilies_classify() {
        #expect(AnthropicModelFamily.classify("claude-opus-4-1") == .opus41)
        #expect(AnthropicModelFamily.classify("claude-opus-4-1-20250805") == .opus41)
        #expect(AnthropicModelFamily.classify("claude-opus-4-1@20250805") == .opus41)
        #expect(AnthropicModelFamily.classify("claude-opus-4-0") == .opus40)
        #expect(AnthropicModelFamily.classify("claude-opus-4-20250514") == .opus40)
        #expect(AnthropicModelFamily.classify("claude-opus-4@20250514") == .opus40)
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-0") == .sonnet40)
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-20250514") == .sonnet40)
        #expect(AnthropicModelFamily.classify("claude-sonnet-4@20250514") == .sonnet40)
    }

    @Test
    func unknown_forNilOrUnrecognized() {
        #expect(AnthropicModelFamily.classify(nil) == .unknown)
        #expect(AnthropicModelFamily.classify("not-a-claude-model") == .unknown)
        #expect(AnthropicModelFamily.classify("gpt-5.4") == .unknown)
        #expect(AnthropicModelFamily.classify("claude-opus-3-5") == .unknown)
        #expect(AnthropicModelFamily.classify("claude-haiku-3-5") == .unknown)
        #expect(AnthropicModelFamily.classify("claude-opus-5-0") == .unknown)
    }

    @Test
    func adjacentNumericSuffix_doesNotCollideWithKnownFamily() {
        #expect(AnthropicModelFamily.classify("claude-opus-4-71") == .unknown)
        #expect(AnthropicModelFamily.classify("claude-opus-4-60") == .unknown)
        #expect(AnthropicModelFamily.classify("claude-opus-4-50") == .unknown)
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-60") == .unknown)
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-50") == .unknown)
        #expect(AnthropicModelFamily.classify("claude-haiku-4-50") == .unknown)
    }

    @Test
    func opus46_sonnet46_opus47_acceptAtSuffix() {
        #expect(AnthropicModelFamily.classify("claude-opus-4-7@20260101") == .opus47)
        #expect(AnthropicModelFamily.classify("claude-sonnet-4-6@20250929") == .sonnet46)
        #expect(AnthropicModelFamily.classify("claude-opus-4-6@20251201") == .opus46)
    }
}

// MARK: - Anthropic capability resolution

struct AnthropicCapabilityResolutionTests {
    @Test
    func opus47_requiresAdaptive_andInterleavedBetaUnsupported() {
        let direct = AnthropicCapabilities.resolve(model: "claude-opus-4-7", transport: .direct)
        #expect(direct.reasoningPolicy == .adaptiveRequired)
        #expect(direct.interleavedBetaPolicy == .unsupported)
        let vertex = AnthropicCapabilities.resolve(model: "claude-opus-4-7", transport: .vertex)
        #expect(vertex.reasoningPolicy == .adaptiveRequired)
        #expect(vertex.interleavedBetaPolicy == .unsupported)
    }

    @Test
    func opus46_direct_betaDeprecatedIgnored_vertex_unsupported() {
        let direct = AnthropicCapabilities.resolve(model: "claude-opus-4-6", transport: .direct)
        #expect(direct.reasoningPolicy == .adaptivePreferred)
        #expect(direct.interleavedBetaPolicy == .deprecatedIgnored)
        let vertex = AnthropicCapabilities.resolve(model: "claude-opus-4-6", transport: .vertex)
        #expect(vertex.interleavedBetaPolicy == .unsupported)
    }

    @Test
    func sonnet46_direct_andVertex_betaDeprecatedAccepted() {
        let direct = AnthropicCapabilities.resolve(model: "claude-sonnet-4-6", transport: .direct)
        #expect(direct.reasoningPolicy == .adaptivePreferred)
        #expect(direct.interleavedBetaPolicy == .deprecatedAccepted)
        let vertex = AnthropicCapabilities.resolve(model: "claude-sonnet-4-6", transport: .vertex)
        #expect(vertex.interleavedBetaPolicy == .deprecatedAccepted)
    }

    @Test
    func haiku45_manualOnly_andVertexRejectsInterleavedBeta() {
        let direct = AnthropicCapabilities.resolve(
            model: "claude-haiku-4-5-20251001", transport: .direct
        )
        #expect(direct.reasoningPolicy == .manualOnly)
        #expect(direct.interleavedBetaPolicy == .manualRequired)
        let vertex = AnthropicCapabilities.resolve(
            model: "claude-haiku-4-5@20251001", transport: .vertex
        )
        #expect(vertex.interleavedBetaPolicy == .unsupported)
    }

    @Test
    func opus45_manualOnly_requiresBetaForInterleaving() {
        let capabilities = AnthropicCapabilities.resolve(
            model: "claude-opus-4-5", transport: .direct
        )
        #expect(capabilities.reasoningPolicy == .manualOnly)
        #expect(capabilities.interleavedBetaPolicy == .manualRequired)
    }

    @Test
    func sonnet45_andOpus41_areManualOnly() {
        let sonnet45 = AnthropicCapabilities.resolve(model: "claude-sonnet-4-5", transport: .direct)
        #expect(sonnet45.reasoningPolicy == .manualOnly)
        #expect(sonnet45.interleavedBetaPolicy == .manualRequired)

        let opus41 = AnthropicCapabilities.resolve(model: "claude-opus-4-1", transport: .direct)
        #expect(opus41.reasoningPolicy == .manualOnly)
        #expect(opus41.interleavedBetaPolicy == .manualRequired)
    }

    @Test
    func unknownModel_hasUnknownReasoningAndBetaPolicies() {
        let capabilities = AnthropicCapabilities.resolve(model: nil, transport: .direct)
        #expect(capabilities.reasoningPolicy == .unknown)
        #expect(capabilities.interleavedBetaPolicy == .unknown)
        #expect(capabilities.supportsForcedToolChoice == false)
        #expect(capabilities.supportsThinkingDisabled == false)
    }
}

// MARK: - Gemini model family classification and resolution

struct GeminiCapabilityTests {
    @Test
    func classify_gemini25() {
        #expect(GeminiModelFamily.classify("gemini-2.5-flash") == .gemini25)
        #expect(GeminiModelFamily.classify("gemini-2.5-pro") == .gemini25)
    }

    @Test
    func classify_gemini3_andGemini31() {
        #expect(GeminiModelFamily.classify("gemini-3-flash-preview") == .gemini3)
        #expect(GeminiModelFamily.classify("gemini-3.1-pro-preview") == .gemini31)
        #expect(GeminiModelFamily.classify("gemini-3-1-pro") == .gemini31)
    }

    @Test
    func classify_unknown() {
        #expect(GeminiModelFamily.classify(nil) == .unknown)
        #expect(GeminiModelFamily.classify("gemini-1.5-flash") == .unknown)
    }

    @Test
    func resolve_gemini25_usesThinkingBudgetAndLegacySchema() {
        let capabilities = GeminiCapabilities.resolve(model: "gemini-2.5-flash")
        #expect(capabilities.thinkingShape == .budget)
        #expect(capabilities.preferredSchemaField == .responseSchema)
        #expect(capabilities.supportsAllowedFunctionNames)
    }

    @Test
    func resolve_gemini3_usesThinkingLevelAndJsonSchema() {
        let capabilities = GeminiCapabilities.resolve(model: "gemini-3-flash-preview")
        #expect(capabilities.thinkingShape == .level)
        #expect(capabilities.preferredSchemaField == .responseJsonSchema)
    }

    @Test
    func resolve_gemini31_inheritsGemini3Shape() {
        let capabilities = GeminiCapabilities.resolve(model: "gemini-3.1-pro-preview")
        #expect(capabilities.thinkingShape == .level)
        #expect(capabilities.preferredSchemaField == .responseJsonSchema)
    }

    @Test
    func resolve_unknown_defaultsToJsonSchema() {
        let capabilities = GeminiCapabilities.resolve(model: nil)
        #expect(capabilities.thinkingShape == .unknown)
        #expect(capabilities.preferredSchemaField == .responseJsonSchema)
    }
}

// MARK: - OpenAI Chat capabilities

struct OpenAIChatCapabilitiesTests {
    @Test
    func firstParty_enablesCustomToolsStrictAndMaxCompletionTokens() {
        let capabilities = OpenAIChatCapabilities.resolve(profile: .firstParty)
        #expect(capabilities.supportsCustomTools)
        #expect(capabilities.supportsStrictFunctionSchemas)
        #expect(capabilities.tokenLimitField == .maxCompletionTokens)
    }

    @Test
    func openRouter_rejectsCustomToolsAndStrict_usesMaxTokens() {
        let capabilities = OpenAIChatCapabilities.resolve(profile: .openRouter)
        #expect(capabilities.supportsCustomTools == false)
        #expect(capabilities.supportsStrictFunctionSchemas == false)
        #expect(capabilities.tokenLimitField == .maxTokens)
    }

    @Test
    func compatible_rejectsCustomToolsAndStrict_usesMaxTokens() {
        let capabilities = OpenAIChatCapabilities.resolve(profile: .compatible)
        #expect(capabilities.supportsCustomTools == false)
        #expect(capabilities.supportsStrictFunctionSchemas == false)
        #expect(capabilities.tokenLimitField == .maxTokens)
    }
}
