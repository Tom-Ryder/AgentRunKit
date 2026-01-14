import Foundation

public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case networkError(description: String)
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case rateLimited(retryAfter: Duration?)
    case encodingFailed(description: String)
    case decodingFailed(description: String)
    case noChoices
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
        case let .other(message): message
        }
    }
}

@available(*, deprecated, renamed: "TransportError")
public typealias OpenAIClientError = TransportError
