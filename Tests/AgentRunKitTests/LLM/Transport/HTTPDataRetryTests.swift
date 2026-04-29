import AgentRunKit
import Foundation
import Testing

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private enum ScriptedResponse {
    case http(statusCode: Int, headers: [String: String], body: Data)
    case networkError(URLError)
}

/// @unchecked Sendable justification: URLProtocol callbacks cross concurrency domains and
/// NSLock guards the scripted response queue.
private final class ScriptedURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ScriptedResponse] = []
    private var observed = 0

    func enqueue(_ responses: [ScriptedResponse]) {
        lock.withLock {
            queue = responses
            observed = 0
        }
    }

    func nextResponse() -> ScriptedResponse? {
        lock.withLock {
            observed += 1
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }
    }

    func observedCount() -> Int {
        lock.withLock { observed }
    }
}

/// @unchecked Sendable justification: URLProtocol is Foundation infrastructure and all
/// shared mutable state lives in ScriptedURLProtocolState.
private final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    fileprivate static let state = ScriptedURLProtocolState()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let scripted = Self.state.nextResponse() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch scripted {
        case let .networkError(urlError):
            client?.urlProtocol(self, didFailWithError: urlError)
            return
        case let .http(statusCode, headers, body):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// @unchecked Sendable justification: URLProtocol is Foundation infrastructure and has no
/// shared mutable state.
private final class CancelledURLProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelledURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}

private func makeRequest() throws -> URLRequest {
    let url = try #require(URL(string: "https://example.test/data"))
    return URLRequest(url: url)
}

@Suite(.serialized)
struct HTTPDataRetryTests {
    @Test
    func successfulResponseReturnsDataAndResponse() async throws {
        ScriptedURLProtocol.state.enqueue([
            .http(statusCode: 200, headers: [:], body: Data("hello".utf8))
        ])
        let session = ScriptedURLProtocol.session()
        let (data, response) = try await HTTPDataRetry.perform(
            urlRequest: makeRequest(),
            session: session,
            retryPolicy: RetryPolicy(maxAttempts: 1)
        )
        #expect(data == Data("hello".utf8))
        #expect(response.statusCode == 200)
    }

    @Test
    func httpErrorThrowsBareTransportError() async throws {
        ScriptedURLProtocol.state.enqueue([
            .http(statusCode: 500, headers: [:], body: Data("boom".utf8))
        ])
        let session = ScriptedURLProtocol.session()
        do {
            _ = try await HTTPDataRetry.perform(
                urlRequest: makeRequest(),
                session: session,
                retryPolicy: RetryPolicy(maxAttempts: 1)
            )
            Issue.record("Expected TransportError")
        } catch let error as TransportError {
            guard case let .httpError(statusCode, body) = error else {
                Issue.record("Expected .httpError, got \(error)")
                return
            }
            #expect(statusCode == 500)
            #expect(body == "boom")
        } catch {
            Issue.record("Expected TransportError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func retryAfterIsHonoredOn429() async throws {
        ScriptedURLProtocol.state.enqueue([
            .http(statusCode: 429, headers: ["Retry-After": "1"], body: Data()),
            .http(statusCode: 200, headers: [:], body: Data("ok".utf8))
        ])
        let session = ScriptedURLProtocol.session()
        let started = ContinuousClock.now
        let (data, response) = try await HTTPDataRetry.perform(
            urlRequest: makeRequest(),
            session: session,
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1))
        )
        let elapsed = ContinuousClock.now - started
        #expect(data == Data("ok".utf8))
        #expect(response.statusCode == 200)
        #expect(ScriptedURLProtocol.state.observedCount() == 2)
        #expect(elapsed >= .milliseconds(900))
        #expect(elapsed < .seconds(3))
    }

    @Test
    func exhaustedRetriesOn429ThrowRateLimited() async throws {
        ScriptedURLProtocol.state.enqueue([
            .http(statusCode: 429, headers: ["Retry-After": "0"], body: Data()),
            .http(statusCode: 429, headers: ["Retry-After": "0"], body: Data()),
            .http(statusCode: 429, headers: ["Retry-After": "7"], body: Data())
        ])
        let session = ScriptedURLProtocol.session()
        do {
            _ = try await HTTPDataRetry.perform(
                urlRequest: makeRequest(),
                session: session,
                retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1))
            )
            Issue.record("Expected TransportError.rateLimited")
        } catch let error as TransportError {
            guard case let .rateLimited(retryAfter) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(retryAfter == .seconds(7))
        } catch {
            Issue.record("Expected TransportError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func nonRetryableStatusFailsImmediately() async throws {
        ScriptedURLProtocol.state.enqueue([
            .http(statusCode: 400, headers: [:], body: Data("bad".utf8)),
            .http(statusCode: 200, headers: [:], body: Data("never".utf8))
        ])
        let session = ScriptedURLProtocol.session()
        do {
            _ = try await HTTPDataRetry.perform(
                urlRequest: makeRequest(),
                session: session,
                retryPolicy: RetryPolicy(maxAttempts: 3)
            )
            Issue.record("Expected TransportError")
        } catch let error as TransportError {
            guard case let .httpError(statusCode, _) = error else {
                Issue.record("Expected .httpError, got \(error)")
                return
            }
            #expect(statusCode == 400)
            #expect(ScriptedURLProtocol.state.observedCount() == 1)
        } catch {
            Issue.record("Expected TransportError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func multiAttempt500ExhaustsAndReportsLastError() async throws {
        ScriptedURLProtocol.state.enqueue([
            .http(statusCode: 500, headers: [:], body: Data("first".utf8)),
            .http(statusCode: 500, headers: [:], body: Data("second".utf8)),
            .http(statusCode: 500, headers: [:], body: Data("third".utf8))
        ])
        let session = ScriptedURLProtocol.session()
        do {
            _ = try await HTTPDataRetry.perform(
                urlRequest: makeRequest(),
                session: session,
                retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1))
            )
            Issue.record("Expected TransportError")
        } catch let error as TransportError {
            guard case let .httpError(statusCode, body) = error else {
                Issue.record("Expected .httpError, got \(error)")
                return
            }
            #expect(statusCode == 500)
            #expect(body == "third")
            #expect(ScriptedURLProtocol.state.observedCount() == 3)
        } catch {
            Issue.record("Expected TransportError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func transientNetworkErrorRetriesThenSucceeds() async throws {
        ScriptedURLProtocol.state.enqueue([
            .networkError(URLError(.networkConnectionLost)),
            .http(statusCode: 200, headers: [:], body: Data("recovered".utf8))
        ])
        let session = ScriptedURLProtocol.session()
        let (data, response) = try await HTTPDataRetry.perform(
            urlRequest: makeRequest(),
            session: session,
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1))
        )
        #expect(data == Data("recovered".utf8))
        #expect(response.statusCode == 200)
        #expect(ScriptedURLProtocol.state.observedCount() == 2)
    }

    @Test
    func cancelledTaskMakesAtMostOneAttempt() async {
        ScriptedURLProtocol.state.enqueue([
            .http(statusCode: 500, headers: [:], body: Data("a".utf8)),
            .http(statusCode: 500, headers: [:], body: Data("b".utf8)),
            .http(statusCode: 500, headers: [:], body: Data("c".utf8)),
            .http(statusCode: 500, headers: [:], body: Data("d".utf8)),
            .http(statusCode: 500, headers: [:], body: Data("e".utf8))
        ])
        let session = ScriptedURLProtocol.session()
        let task = Task {
            try await HTTPDataRetry.perform(
                urlRequest: makeRequest(),
                session: session,
                retryPolicy: RetryPolicy(maxAttempts: 5, baseDelay: .milliseconds(50))
            )
        }
        task.cancel()
        _ = try? await task.value
        #expect(ScriptedURLProtocol.state.observedCount() <= 1)
    }

    @Test
    func urlSessionCancellationErrorDoesNotRetry() async throws {
        ScriptedURLProtocol.state.enqueue([
            .networkError(URLError(.cancelled)),
            .http(statusCode: 200, headers: [:], body: Data("never".utf8))
        ])
        do {
            _ = try await HTTPDataRetry.perform(
                urlRequest: makeRequest(),
                session: ScriptedURLProtocol.session(),
                retryPolicy: RetryPolicy(maxAttempts: 5, baseDelay: .milliseconds(1))
            )
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            #expect(ScriptedURLProtocol.state.observedCount() == 1)
        } catch {
            Issue.record("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func urlSessionCancellationErrorPropagatesAsCancellationError() async throws {
        do {
            _ = try await HTTPDataRetry.perform(
                urlRequest: makeRequest(),
                session: CancelledURLProtocol.session(),
                retryPolicy: RetryPolicy(maxAttempts: 1)
            )
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }
}
