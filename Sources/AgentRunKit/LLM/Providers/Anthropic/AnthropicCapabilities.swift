import Foundation

/// The Anthropic model family that drives capability resolution.
public enum AnthropicModelFamily: Sendable, Equatable {
    case opus47
    case sonnet46
    case haiku45
    case opus46
    case sonnet45
    case opus45
    case opus41
    case sonnet40
    case opus40
    case unknown

    public static func classify(_ modelIdentifier: String?) -> AnthropicModelFamily {
        guard let model = modelIdentifier else { return .unknown }
        if matchesVersionPrefix("claude-opus-4-7", in: model) { return .opus47 }
        if matchesVersionPrefix("claude-sonnet-4-6", in: model) { return .sonnet46 }
        if matchesVersionPrefix("claude-haiku-4-5", in: model) { return .haiku45 }
        if matchesVersionPrefix("claude-opus-4-6", in: model) { return .opus46 }
        if matchesVersionPrefix("claude-sonnet-4-5", in: model) { return .sonnet45 }
        if matchesVersionPrefix("claude-opus-4-5", in: model) { return .opus45 }
        if matchesVersionPrefix("claude-opus-4-1", in: model) { return .opus41 }
        if isSonnet40(model) { return .sonnet40 }
        if isOpus40(model) { return .opus40 }
        return .unknown
    }

    private static func isSonnet40(_ model: String) -> Bool {
        matchesVersionPrefix("claude-sonnet-4-0", in: model)
            || matchesDatePrefix("claude-sonnet-4-20", in: model)
            || model.hasPrefix("claude-sonnet-4@")
    }

    private static func isOpus40(_ model: String) -> Bool {
        matchesVersionPrefix("claude-opus-4-0", in: model)
            || matchesDatePrefix("claude-opus-4-20", in: model)
            || model.hasPrefix("claude-opus-4@")
    }

    private static func matchesVersionPrefix(_ prefix: String, in model: String) -> Bool {
        guard model.hasPrefix(prefix) else { return false }
        guard model.count > prefix.count else { return true }
        let nextIndex = model.index(model.startIndex, offsetBy: prefix.count)
        return !model[nextIndex].isNumber
    }

    private static func matchesDatePrefix(_ prefix: String, in model: String) -> Bool {
        guard model.hasPrefix(prefix) else { return false }
        guard model.count > prefix.count else { return false }
        let nextIndex = model.index(model.startIndex, offsetBy: prefix.count)
        return model[nextIndex].isNumber
    }
}

/// Capabilities of an Anthropic Messages endpoint for a given model and transport.
public struct AnthropicCapabilities: Sendable, Equatable {
    public let family: AnthropicModelFamily
    public let transport: Transport
    public let reasoningPolicy: ReasoningPolicy
    public let interleavedBetaPolicy: InterleavedBetaPolicy
    public let supportsThinkingDisabled: Bool
    public let supportsForcedToolChoice: Bool

    /// The transport through which the Anthropic API is reached.
    public enum Transport: Sendable, Equatable {
        case direct
        case vertex
    }

    /// The reasoning modes the provider accepts for this model and transport.
    public enum ReasoningPolicy: Sendable, Equatable {
        case adaptiveRequired
        case adaptivePreferred
        case manualOnly
        case unknown
    }

    /// How the provider treats the `interleaved-thinking-2025-05-14` beta header for this model and transport.
    public enum InterleavedBetaPolicy: Sendable, Equatable {
        case unsupported
        case deprecatedIgnored
        case deprecatedAccepted
        case manualRequired
        case unknown
    }

    public init(
        family: AnthropicModelFamily,
        transport: Transport,
        reasoningPolicy: ReasoningPolicy,
        interleavedBetaPolicy: InterleavedBetaPolicy,
        supportsThinkingDisabled: Bool,
        supportsForcedToolChoice: Bool
    ) {
        self.family = family
        self.transport = transport
        self.reasoningPolicy = reasoningPolicy
        self.interleavedBetaPolicy = interleavedBetaPolicy
        self.supportsThinkingDisabled = supportsThinkingDisabled
        self.supportsForcedToolChoice = supportsForcedToolChoice
    }

    public static func resolve(model: String?, transport: Transport) -> AnthropicCapabilities {
        let family = AnthropicModelFamily.classify(model)
        return AnthropicCapabilities(
            family: family,
            transport: transport,
            reasoningPolicy: reasoningPolicy(for: family),
            interleavedBetaPolicy: interleavedBetaPolicy(family: family, transport: transport),
            supportsThinkingDisabled: supportsThinkingDisabled(family: family),
            supportsForcedToolChoice: supportsForcedToolChoice(family: family)
        )
    }

    private static func reasoningPolicy(for family: AnthropicModelFamily) -> ReasoningPolicy {
        switch family {
        case .opus47: .adaptiveRequired
        case .sonnet46, .opus46: .adaptivePreferred
        case .haiku45, .sonnet45, .opus45, .opus41, .sonnet40, .opus40: .manualOnly
        case .unknown: .unknown
        }
    }

    private static func interleavedBetaPolicy(
        family: AnthropicModelFamily,
        transport: Transport
    ) -> InterleavedBetaPolicy {
        switch transport {
        case .vertex:
            switch family {
            case .opus47: .unsupported
            case .haiku45, .opus46: .unsupported
            case .sonnet46: .deprecatedAccepted
            case .sonnet45, .opus45, .opus41, .sonnet40, .opus40: .manualRequired
            case .unknown: .unknown
            }
        case .direct:
            switch family {
            case .opus47: .unsupported
            case .opus46: .deprecatedIgnored
            case .sonnet46: .deprecatedAccepted
            case .haiku45, .sonnet45, .opus45, .opus41, .sonnet40, .opus40: .manualRequired
            case .unknown: .unknown
            }
        }
    }

    private static func supportsThinkingDisabled(family: AnthropicModelFamily) -> Bool {
        family != .unknown
    }

    private static func supportsForcedToolChoice(family: AnthropicModelFamily) -> Bool {
        family != .unknown
    }
}
