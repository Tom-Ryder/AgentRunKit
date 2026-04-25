@testable import AgentRunKit
import Foundation
import Testing

struct ParseRetryAfterTests {
    private func makeResponse(headers: [String: String] = [:]) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://example.com"))
        return try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: headers
        ))
    }

    @Test
    func integerSeconds() throws {
        let duration = try HTTPRetry.parseRetryAfter(makeResponse(headers: ["Retry-After": "30"]))
        #expect(duration == .seconds(30))
    }

    @Test
    func zeroSeconds() throws {
        let duration = try HTTPRetry.parseRetryAfter(makeResponse(headers: ["Retry-After": "0"]))
        #expect(duration == .seconds(0))
    }

    @Test
    func missingHeaderReturnsNil() throws {
        let duration = try HTTPRetry.parseRetryAfter(makeResponse())
        #expect(duration == nil)
    }

    @Test
    func malformedValueReturnsNil() throws {
        let duration = try HTTPRetry.parseRetryAfter(makeResponse(headers: ["Retry-After": "abc"]))
        #expect(duration == nil)
    }

    @Test
    func futureHTTPDateReturnsDuration() throws {
        let futureDate = Date().addingTimeInterval(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let response = try makeResponse(headers: ["Retry-After": formatter.string(from: futureDate)])
        let duration = HTTPRetry.parseRetryAfter(response)
        #expect(duration != nil)
        if let duration {
            let seconds = duration.components.seconds
            #expect(seconds >= 55 && seconds <= 65)
        }
    }

    @Test
    func pastHTTPDateReturnsZero() throws {
        let pastDate = Date().addingTimeInterval(-60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let response = try makeResponse(headers: ["Retry-After": formatter.string(from: pastDate)])
        let duration = HTTPRetry.parseRetryAfter(response)
        #expect(duration == .seconds(0))
    }
}

struct ParseHTTPDateTests {
    @Test
    func rfc1123Format() {
        let date = HTTPRetry.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(date != nil)
    }

    @Test
    func rfc850Format() {
        let date = HTTPRetry.parseHTTPDate("Sunday, 06-Nov-94 08:49:37 GMT")
        #expect(date != nil)
    }

    @Test
    func asctimeFormat() {
        let date = HTTPRetry.parseHTTPDate("Sun Nov  6 08:49:37 1994")
        #expect(date != nil)
    }

    @Test
    func invalidStringReturnsNil() {
        let date = HTTPRetry.parseHTTPDate("not-a-date")
        #expect(date == nil)
    }

    @Test
    func emptyStringReturnsNil() {
        let date = HTTPRetry.parseHTTPDate("")
        #expect(date == nil)
    }
}

struct HandleErrorStatusTests {
    @Test
    func nonRateLimitReturnsStop() async throws {
        let url = try #require(URL(string: "https://example.com"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 500,
            httpVersion: nil,
            headerFields: [:]
        ))
        var slept = false
        let result = try await HTTPRetry.handleErrorStatus(
            httpResponse: response,
            errorBody: "Internal Server Error",
            attempt: 0,
            retryPolicy: .default,
            sleptForRetryAfter: &slept
        )
        guard case let .stop(error) = result else {
            Issue.record("Expected .stop, got .continue")
            return
        }
        if case let .httpError(statusCode, body) = error as? TransportError {
            #expect(statusCode == 500)
            #expect(body == "Internal Server Error")
        } else {
            Issue.record("Expected .httpError")
        }
    }

    @Test
    func rateLimitOnLastAttemptReturnsStop() async throws {
        let url = try #require(URL(string: "https://example.com"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: [:]
        ))
        let policy = RetryPolicy(maxAttempts: 3)
        var slept = false
        let result = try await HTTPRetry.handleErrorStatus(
            httpResponse: response,
            errorBody: "",
            attempt: 2,
            retryPolicy: policy,
            sleptForRetryAfter: &slept
        )
        guard case let .stop(error) = result else {
            Issue.record("Expected .stop, got .continue")
            return
        }
        if case .rateLimited = error as? TransportError {
            // expected
        } else {
            Issue.record("Expected .rateLimited, got \(error)")
        }
    }
}
