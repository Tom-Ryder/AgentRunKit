import Foundation

/// Exponential backoff with jitter for retrying transient LLM failures.
public struct RetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let baseDelay: Duration
    public let maxDelay: Duration
    public let streamStallTimeout: Duration?

    private static let maxExponentialShift = 10

    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30),
        streamStallTimeout: Duration? = nil
    ) {
        precondition(maxAttempts >= 1, "maxAttempts must be at least 1")
        precondition(baseDelay >= .milliseconds(1), "baseDelay must be at least 1ms")
        precondition(maxDelay >= baseDelay, "maxDelay must be at least baseDelay")
        if let streamStallTimeout {
            precondition(streamStallTimeout >= .milliseconds(100), "streamStallTimeout must be at least 100ms")
        }
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.streamStallTimeout = streamStallTimeout
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 1)

    func delay(forAttempt attempt: Int) -> Duration {
        let clampedAttempt = min(max(attempt, 0), Self.maxExponentialShift)
        let multiplier = 1 << clampedAttempt
        let exponential = baseDelay * Double(multiplier)
        let capped = min(exponential, maxDelay)
        return capped * Double.random(in: 0.5 ... 1.0)
    }

    static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    func isRetryable(statusCode: Int) -> Bool {
        Self.retryableStatusCodes.contains(statusCode)
    }
}
