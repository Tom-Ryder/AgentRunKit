import Foundation

/// A public retry facade shared by ``OpenAITTSProvider`` and custom HTTP-backed providers.
public enum HTTPDataRetry: Sendable {
    /// Sends the request with retry, throwing bare ``TransportError`` or `CancellationError`.
    public static func perform(
        urlRequest: URLRequest,
        session: URLSession,
        retryPolicy: RetryPolicy
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await HTTPRetry.performData(
                urlRequest: urlRequest,
                session: session,
                retryPolicy: retryPolicy
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let AgentError.llmError(transportError) {
            throw transportError
        }
    }
}
