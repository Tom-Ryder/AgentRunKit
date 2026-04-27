import Foundation

/// Identifies the provider that produced an LLM event or error.
public enum ProviderIdentifier: Sendable, Equatable, Hashable, CustomStringConvertible {
    case openAI
    case openRouter
    case openAICompatible
    case openAIResponses
    case anthropic
    case gemini
    case vertexAnthropic
    case vertexGoogle
    case foundationModels
    case mlx
    case custom(String)

    public var description: String {
        switch self {
        case .openAI: "openai"
        case .openRouter: "openrouter"
        case .openAICompatible: "openai-compatible"
        case .openAIResponses: "openai-responses"
        case .anthropic: "anthropic"
        case .gemini: "gemini"
        case .vertexAnthropic: "vertex-anthropic"
        case .vertexGoogle: "vertex-google"
        case .foundationModels: "foundation-models"
        case .mlx: "mlx"
        case let .custom(value): value
        }
    }
}

/// Diagnostic payload for stream failures.
///
/// Equatable conformance compares all fields exactly, including `elapsed`. Tests should prefer pattern matching
/// and tolerant elapsed-time assertions when diagnostics come from wall-clock measurements.
public struct StreamFailureDiagnostics: Sendable, Equatable {
    public let elapsed: Duration
    public let eventsObserved: Int
    public let lastEvent: String?

    public init(elapsed: Duration, eventsObserved: Int, lastEvent: String?) {
        self.elapsed = elapsed
        self.eventsObserved = eventsObserved
        self.lastEvent = lastEvent
    }
}

/// A typed failure from an LLM stream after the HTTP stream has started.
public enum StreamFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case idleTimeout(diagnostics: StreamFailureDiagnostics)
    case providerTerminationMissing(diagnostics: StreamFailureDiagnostics)
    case finishedDeltaMissing(diagnostics: StreamFailureDiagnostics)
    case midStreamTransportFailure(code: URLError.Code, diagnostics: StreamFailureDiagnostics)
    case providerError(provider: ProviderIdentifier, code: String?, message: String)
    case malformedStream(reason: MalformedStreamReason, diagnostics: StreamFailureDiagnostics)

    public var description: String {
        switch self {
        case let .idleTimeout(diagnostics):
            "Stream idle timeout after \(diagnostics.eventsObserved) events"
        case let .providerTerminationMissing(diagnostics):
            "Stream ended before provider completion after \(diagnostics.eventsObserved) events"
        case let .finishedDeltaMissing(diagnostics):
            "Stream ended without a finished delta after \(diagnostics.eventsObserved) events"
        case let .midStreamTransportFailure(code, diagnostics):
            "Stream transport failed with \(code) after \(diagnostics.eventsObserved) events"
        case let .providerError(provider, code, message):
            if let code {
                "\(provider) stream error \(code): \(message)"
            } else {
                "\(provider) stream error: \(message)"
            }
        case let .malformedStream(reason, _):
            "Malformed stream: \(reason)"
        }
    }
}

/// Errors from HTTP transport and response parsing.
public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case streamFailed(StreamFailure)
    case networkError(code: URLError.Code?, description: String)
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case rateLimited(retryAfter: Duration?)
    case encodingFailed(description: String)
    case decodingFailed(description: String)
    case noChoices
    case capabilityMismatch(model: String, requirement: String)
    case featureUnsupported(provider: String, feature: String)
    case other(String)

    public static func networkError(_ error: some Error) -> TransportError {
        if let urlError = error as? URLError {
            return .networkError(code: urlError.code, description: "URL request failed")
        }
        return .networkError(code: nil, description: "Network request failed")
    }

    public static func encodingFailed(_ error: some Error) -> TransportError {
        .encodingFailed(description: String(describing: error))
    }

    public static func decodingFailed(_ error: some Error) -> TransportError {
        .decodingFailed(description: String(describing: error))
    }

    public var description: String {
        switch self {
        case let .streamFailed(failure): "Stream failed: \(failure)"
        case let .networkError(code, description):
            if let code {
                "Network error (\(code)): \(description)"
            } else {
                "Network error: \(description)"
            }
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
        case let .streamFailed(.providerError(_, code, message)):
            return Self.matchesPromptTooLongOtherMessage(in: [code, message].compactMap(\.self).joined(separator: ": "))
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
