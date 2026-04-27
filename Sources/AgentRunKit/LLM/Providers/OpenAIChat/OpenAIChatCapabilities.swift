import Foundation

/// The OpenAI Chat Completions backend an `OpenAIClient` talks to.
public enum OpenAIChatProfile: Sendable, Equatable, CaseIterable, CustomStringConvertible {
    case firstParty
    case openRouter
    case compatible

    public var description: String {
        switch self {
        case .firstParty:
            "first-party"
        case .openRouter:
            "open-router"
        case .compatible:
            "compatible"
        }
    }

    var providerIdentifier: ProviderIdentifier {
        switch self {
        case .firstParty:
            .openAI
        case .openRouter:
            .openRouter
        case .compatible:
            .openAICompatible
        }
    }
}

/// Capabilities that vary by `OpenAIChatProfile`.
public struct OpenAIChatCapabilities: Sendable, Equatable {
    public let profile: OpenAIChatProfile
    public let supportsCustomTools: Bool
    public let supportsStrictFunctionSchemas: Bool
    public let tokenLimitField: TokenLimitField

    public enum TokenLimitField: String, Sendable, Equatable {
        case maxCompletionTokens = "max_completion_tokens"
        case maxTokens = "max_tokens"
    }

    public init(
        profile: OpenAIChatProfile,
        supportsCustomTools: Bool,
        supportsStrictFunctionSchemas: Bool,
        tokenLimitField: TokenLimitField
    ) {
        self.profile = profile
        self.supportsCustomTools = supportsCustomTools
        self.supportsStrictFunctionSchemas = supportsStrictFunctionSchemas
        self.tokenLimitField = tokenLimitField
    }

    public static func resolve(profile: OpenAIChatProfile) -> OpenAIChatCapabilities {
        switch profile {
        case .firstParty:
            OpenAIChatCapabilities(
                profile: profile,
                supportsCustomTools: true,
                supportsStrictFunctionSchemas: true,
                tokenLimitField: .maxCompletionTokens
            )
        case .openRouter, .compatible:
            OpenAIChatCapabilities(
                profile: profile,
                supportsCustomTools: false,
                supportsStrictFunctionSchemas: false,
                tokenLimitField: .maxTokens
            )
        }
    }
}
