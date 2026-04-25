import Foundation

/// The Gemini model family that drives capability resolution.
public enum GeminiModelFamily: Sendable, Equatable {
    case gemini25
    case gemini3
    case gemini31
    case unknown

    public static func classify(_ modelIdentifier: String?) -> GeminiModelFamily {
        guard let model = modelIdentifier else { return .unknown }
        if model.hasPrefix("gemini-3.1") || model.hasPrefix("gemini-3-1") { return .gemini31 }
        if model.hasPrefix("gemini-3") { return .gemini3 }
        if model.hasPrefix("gemini-2.5") || model.hasPrefix("gemini-2-5") { return .gemini25 }
        return .unknown
    }
}

/// Capabilities of a Gemini `generateContent` endpoint for a given model.
public struct GeminiCapabilities: Sendable, Equatable {
    public let family: GeminiModelFamily
    public let thinkingShape: ThinkingShape
    public let supportsAllowedFunctionNames: Bool
    public let preferredSchemaField: PreferredSchemaField

    /// How `thinkingConfig` is expressed for the model family.
    public enum ThinkingShape: Sendable, Equatable {
        case budget
        case level
        case unknown
    }

    /// The field name used for structured-output schema definitions.
    public enum PreferredSchemaField: String, Sendable, Equatable {
        case responseJsonSchema
        case responseSchema
    }

    public init(
        family: GeminiModelFamily,
        thinkingShape: ThinkingShape,
        supportsAllowedFunctionNames: Bool,
        preferredSchemaField: PreferredSchemaField
    ) {
        self.family = family
        self.thinkingShape = thinkingShape
        self.supportsAllowedFunctionNames = supportsAllowedFunctionNames
        self.preferredSchemaField = preferredSchemaField
    }

    public static func resolve(model: String?) -> GeminiCapabilities {
        let family = GeminiModelFamily.classify(model)
        switch family {
        case .gemini25:
            return GeminiCapabilities(
                family: family,
                thinkingShape: .budget,
                supportsAllowedFunctionNames: true,
                preferredSchemaField: .responseSchema
            )
        case .gemini3, .gemini31:
            return GeminiCapabilities(
                family: family,
                thinkingShape: .level,
                supportsAllowedFunctionNames: true,
                preferredSchemaField: .responseJsonSchema
            )
        case .unknown:
            return GeminiCapabilities(
                family: family,
                thinkingShape: .unknown,
                supportsAllowedFunctionNames: true,
                preferredSchemaField: .responseJsonSchema
            )
        }
    }
}
