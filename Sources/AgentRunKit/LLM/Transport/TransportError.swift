import Foundation

/// Errors from HTTP transport and response parsing.
public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case networkError(description: String)
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case rateLimited(retryAfter: Duration?)
    case encodingFailed(description: String)
    case decodingFailed(description: String)
    case noChoices
    case streamStalled
    case capabilityMismatch(model: String, requirement: String)
    case featureUnsupported(provider: String, feature: String)
    case other(String)

    public static func networkError(_ error: some Error) -> TransportError {
        .networkError(description: String(describing: error))
    }

    public static func encodingFailed(_ error: some Error) -> TransportError {
        .encodingFailed(description: String(describing: error))
    }

    public static func decodingFailed(_ error: some Error) -> TransportError {
        .decodingFailed(description: String(describing: error))
    }

    public var description: String {
        switch self {
        case let .networkError(description): "Network error: \(description)"
        case .invalidResponse: "Invalid response"
        case let .httpError(statusCode, body): "HTTP \(statusCode): \(body)"
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Rate limited, retry after \(retryAfter)"
            } else {
                "Rate limited"
            }
        case let .encodingFailed(description): "Encoding failed: \(description)"
        case let .decodingFailed(description): "Decoding failed: \(description)"
        case .noChoices: "No choices in response"
        case .streamStalled: "Stream stalled or ended before completion"
        case let .capabilityMismatch(model, requirement):
            "Capability mismatch for model '\(model)': \(requirement)"
        case let .featureUnsupported(provider, feature):
            "Feature '\(feature)' is unsupported on provider '\(provider)'"
        case let .other(message): message
        }
    }
}

extension TransportError {
    var isPromptTooLong: Bool {
        switch self {
        case let .httpError(statusCode, body):
            guard statusCode == 400 else {
                return false
            }
            return Self.matchesPromptTooLongHTTPBody(in: body)
        case let .other(message):
            return Self.matchesPromptTooLongOtherMessage(in: message)
        default:
            return false
        }
    }

    private static func matchesPromptTooLongHTTPBody(in source: String) -> Bool {
        let normalized = normalizedPromptTooLongSource(source)

        if normalized.contains("context_length_exceeded") {
            return true
        }
        if normalized.contains("maximum context length") {
            return true
        }
        if hasPromptTooLongPhrase(normalized),
           hasOverflowScaleMarker(normalized),
           hasProviderInvalidRequestAnchor(normalized) {
            return true
        }
        if normalized.contains("input token count"), normalized.contains("maximum number of tokens") {
            return true
        }
        if normalized.contains("exceeds the maximum number of tokens"),
           normalized.contains("input") || normalized.contains("prompt") || normalized.contains("context") {
            return true
        }

        return false
    }

    private static func matchesPromptTooLongOtherMessage(in source: String) -> Bool {
        let normalized = normalizedPromptTooLongSource(source)

        if normalized.contains("context_length_exceeded") {
            return true
        }
        if normalized.contains("maximum context length") {
            return true
        }
        if hasProviderInvalidRequestAnchor(normalized),
           hasPromptTooLongPhrase(normalized),
           hasOverflowScaleMarker(normalized) {
            return true
        }
        if normalized.contains("invalid_argument"),
           normalized.contains("input token count"),
           normalized.contains("maximum number of tokens") {
            return true
        }
        if normalized.contains("invalid_argument"),
           normalized.contains("exceeds the maximum number of tokens"),
           normalized.contains("input") || normalized.contains("prompt") || normalized.contains("context") {
            return true
        }

        return false
    }

    private static func normalizedPromptTooLongSource(_ source: String) -> String {
        source
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func hasPromptTooLongPhrase(_ normalized: String) -> Bool {
        normalized.contains("prompt is too long") || normalized.contains("prompt too long")
    }

    private static func hasOverflowScaleMarker(_ normalized: String) -> Bool {
        normalized.contains("token") || normalized.contains("maximum")
    }

    private static func hasProviderInvalidRequestAnchor(_ normalized: String) -> Bool {
        normalized.contains("invalid_request_error") || normalized.contains("invalid_argument")
    }
}
