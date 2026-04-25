@testable import AgentRunKit
import Foundation
import Testing

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// @unchecked Sendable justification: URL loading callbacks cross concurrency domains and
/// NSLock guards all shared mutable state in this test helper.
final class StreamingTestURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String: Data] = [:]

    func register(url: URL, body: Data) {
        lock.withLock {
            bodies[url.absoluteString] = body
        }
    }

    func unregister(url: URL) {
        lock.withLock {
            _ = bodies.removeValue(forKey: url.absoluteString)
        }
    }

    func body(for url: URL) -> Data? {
        lock.withLock {
            bodies[url.absoluteString]
        }
    }
}

/// @unchecked Sendable justification: URLProtocol is Foundation class infrastructure and this
/// test double has no mutable instance state outside the locked shared test store.
final class StreamingTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = StreamingTestURLProtocolState()

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingTestURLProtocol.self]
        return configuration
    }

    static func register(url: URL, body: Data) {
        state.register(url: url, body: body)
    }

    static func unregister(url: URL) {
        state.unregister(url: url)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let body = Self.state.body(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func collectStreamResult(
    _ stream: AsyncThrowingStream<StreamDelta, Error>
) async -> (deltas: [StreamDelta], error: (any Error)?) {
    var deltas: [StreamDelta] = []
    do {
        for try await delta in stream {
            deltas.append(delta)
        }
        return (deltas, nil)
    } catch {
        return (deltas, error)
    }
}

func assertStreamStalled(_ error: (any Error)?) {
    guard let agentError = error as? AgentError,
          case let .llmError(transport) = agentError else {
        Issue.record("Expected streamStalled, got \(String(describing: error))")
        return
    }
    #expect(transport == .streamStalled)
}
