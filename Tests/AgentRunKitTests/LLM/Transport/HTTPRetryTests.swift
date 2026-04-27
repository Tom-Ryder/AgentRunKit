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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// @unchecked Sendable justification: URLProtocol callbacks cross concurrency domains and
/// NSLock guards the shared route used by this test transport.
private final class FailingErrorBodyURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: URLError?

    func setFailure(_ failure: URLError?) {
        lock.withLock {
            self.failure = failure
        }
    }

    func currentFailure() -> URLError? {
        lock.withLock { failure }
    }
}

/// @unchecked Sendable justification: URLProtocol is Foundation infrastructure and all
/// shared mutable state lives in FailingErrorBodyURLProtocolState.
private final class FailingErrorBodyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = FailingErrorBodyURLProtocolState()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingErrorBodyURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func setFailure(_ failure: URLError?) {
        state.setFailure(failure)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 500,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "text/plain"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didFailWithError: Self.state.currentFailure() ?? URLError(.timedOut))
    }

    override func stopLoading() {}
}

private enum SecretURLLoadingMode {
    case failBeforeResponse(URLError)
    case failAfterBody(Data, URLError)
}

/// @unchecked Sendable justification: URLProtocol callbacks cross concurrency domains and
/// NSLock guards the configured loading mode.
private final class SecretURLLoadingProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var mode: SecretURLLoadingMode?

    func setMode(_ mode: SecretURLLoadingMode?) {
        lock.withLock {
            self.mode = mode
        }
    }

    func currentMode() -> SecretURLLoadingMode? {
        lock.withLock { mode }
    }
}

/// @unchecked Sendable justification: URLProtocol is Foundation infrastructure and all
/// shared mutable state lives in SecretURLLoadingProtocolState.
private final class SecretURLLoadingProtocol: URLProtocol, @unchecked Sendable {
    private static let state = SecretURLLoadingProtocolState()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SecretURLLoadingProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func setMode(_ mode: SecretURLLoadingMode?) {
        state.setMode(mode)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let mode = Self.state.currentMode() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch mode {
        case let .failBeforeResponse(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .failAfterBody(body, error):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "text/event-stream"]
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

struct HTTPRetryStreamBodySanitizationTests {
    private func secretFailure() throws -> URLError {
        let secretURL = try #require(URL(string: "https://example.test?key=AIzaSyTEST&authorization=BearerSecret"))
        return URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: secretURL.absoluteString,
                NSURLErrorFailingURLErrorKey: secretURL as Any,
                NSLocalizedDescriptionKey: "BearerSecret key=AIzaSyTEST"
            ]
        )
    }

    private func assertSanitized(_ error: any Error) {
        let described = String(describing: error)
        let reflected = String(reflecting: error)
        for text in [described, reflected] {
            #expect(!text.contains("key="))
            #expect(!text.contains("AIza"))
            #expect(!text.contains("Bearer"))
        }
    }

    @Test
    func streamErrorBodyReadFailureDoesNotExposeUnderlyingURL() async throws {
        let failure = try secretFailure()
        FailingErrorBodyURLProtocol.setFailure(failure)
        defer { FailingErrorBodyURLProtocol.setFailure(nil) }
        let request = try URLRequest(url: #require(URL(string: "https://transport.test/stream")))

        do {
            _ = try await HTTPRetry.performStream(
                urlRequest: request,
                session: FailingErrorBodyURLProtocol.session(),
                retryPolicy: RetryPolicy(maxAttempts: 1)
            )
            Issue.record("Expected HTTP error")
        } catch {
            assertSanitized(error)
        }
    }

    @Test
    func preStreamURLSessionFailuresDoNotExposeUnderlyingURL() async throws {
        let failure = try secretFailure()
        SecretURLLoadingProtocol.setMode(.failBeforeResponse(failure))
        defer { SecretURLLoadingProtocol.setMode(nil) }
        let request = try URLRequest(url: #require(URL(string: "https://transport.test/preflight")))
        let session = SecretURLLoadingProtocol.session()

        do {
            _ = try await HTTPRetry.performData(
                urlRequest: request,
                session: session,
                retryPolicy: RetryPolicy(maxAttempts: 1)
            )
            Issue.record("Expected data request failure")
        } catch {
            assertSanitized(error)
        }

        do {
            let (bytes, _) = try await HTTPRetry.performStream(
                urlRequest: request,
                session: session,
                retryPolicy: RetryPolicy(maxAttempts: 1)
            )
            do {
                try await processSSEStream(bytes: bytes, stallTimeout: nil) { _, _ in false }
                Issue.record("Expected stream request failure")
            } catch {
                assertSanitized(error)
            }
        } catch {
            assertSanitized(error)
        }
    }

    @Test
    func midStreamURLSessionFailureDoesNotExposeUnderlyingURL() async throws {
        let failure = try secretFailure()
        let body = Data("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"index\":0}]}\n\n".utf8)
        SecretURLLoadingProtocol.setMode(.failAfterBody(body, failure))
        defer { SecretURLLoadingProtocol.setMode(nil) }
        let request = try URLRequest(url: #require(URL(string: "https://transport.test/stream")))
        do {
            let (bytes, _) = try await HTTPRetry.performStream(
                urlRequest: request,
                session: SecretURLLoadingProtocol.session(),
                retryPolicy: RetryPolicy(maxAttempts: 1)
            )
            try await processSSEStream(bytes: bytes, stallTimeout: nil) { _, _ in false }
            Issue.record("Expected mid-stream failure")
        } catch {
            assertSanitized(error)
            switch error {
            case let AgentError.llmError(.streamFailed(.midStreamTransportFailure(code, _))):
                #expect(code == .timedOut)
            case let AgentError.llmError(.networkError(code, _)):
                #expect(code == .timedOut)
            default:
                Issue.record("Expected sanitized stream transport failure, got \(error)")
            }
        }
    }
}
