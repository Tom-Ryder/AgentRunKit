import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct RetryPolicyTests {
    @Test
    func defaultValues() {
        let policy = RetryPolicy.default
        #expect(policy.maxAttempts == 3)
        #expect(policy.baseDelay == .seconds(1))
        #expect(policy.maxDelay == .seconds(30))
    }

    @Test
    func noneHasSingleAttempt() {
        let policy = RetryPolicy.none
        #expect(policy.maxAttempts == 1)
    }

    @Test
    func exponentialBackoff() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(1000))
        for _ in 0 ..< 10 {
            let delay0 = policy.delay(forAttempt: 0)
            let delay1 = policy.delay(forAttempt: 1)
            let delay2 = policy.delay(forAttempt: 2)
            #expect(delay0 >= .milliseconds(500) && delay0 <= .seconds(1))
            #expect(delay1 >= .seconds(1) && delay1 <= .seconds(2))
            #expect(delay2 >= .seconds(2) && delay2 <= .seconds(4))
        }
    }

    @Test
    func maxDelayCapped() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(5))
        for _ in 0 ..< 10 {
            let d10 = policy.delay(forAttempt: 10)
            #expect(d10 <= .seconds(5))
        }
    }

    @Test
    func jitterApplied() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: .seconds(10), maxDelay: .seconds(100))
        var delays: Set<Int64> = []
        for _ in 0 ..< 20 {
            let delay = policy.delay(forAttempt: 0)
            delays.insert(delay.components.attoseconds)
        }
        #expect(delays.count > 1)
    }

    @Test
    func retryableStatusCodes() {
        let policy = RetryPolicy.default
        #expect(policy.isRetryable(statusCode: 408))
        #expect(policy.isRetryable(statusCode: 429))
        #expect(policy.isRetryable(statusCode: 500))
        #expect(policy.isRetryable(statusCode: 502))
        #expect(policy.isRetryable(statusCode: 503))
        #expect(policy.isRetryable(statusCode: 504))
        #expect(!policy.isRetryable(statusCode: 400))
        #expect(!policy.isRetryable(statusCode: 401))
        #expect(!policy.isRetryable(statusCode: 403))
        #expect(!policy.isRetryable(statusCode: 404))
        #expect(!policy.isRetryable(statusCode: 200))
        #expect(!policy.isRetryable(statusCode: 501))
    }
}
