@testable import AgentRunKit
import Foundation

private enum ResponsesTestHelperError: Error {
    case expectedJSONObject
    case missingRecordedBody(URL)
}

private func decodeJSONObject(from data: Data) throws -> [String: Any] {
    let json = try JSONSerialization.jsonObject(with: data)
    guard let object = json as? [String: Any] else {
        throw ResponsesTestHelperError.expectedJSONObject
    }
    return object
}

func encodeRequest(_ request: ResponsesRequest) throws -> [String: Any] {
    let data = try JSONEncoder().encode(request)
    return try decodeJSONObject(from: data)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// @unchecked Sendable justification: URL loading callbacks cross concurrency domains and
/// NSLock guards all shared mutable state in this test helper.
final class ResponsesTestURLProtocolState: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recordedBodies: [String: [Data]] = [:]

    func register(url: URL, handler: @escaping Handler) {
        lock.withLock {
            handlers[url.absoluteString] = handler
        }
    }

    func unregister(url: URL) {
        lock.withLock {
            handlers.removeValue(forKey: url.absoluteString)
            recordedBodies.removeValue(forKey: url.absoluteString)
        }
    }

    func handler(for url: URL) -> Handler? {
        lock.withLock {
            handlers[url.absoluteString]
        }
    }

    func recordBody(_ body: Data, for url: URL) {
        lock.withLock {
            recordedBodies[url.absoluteString, default: []].append(body)
        }
    }

    func recordedBody(for url: URL) -> Data? {
        lock.withLock {
            recordedBodies[url.absoluteString]?.last
        }
    }

    func recordedBodies(for url: URL) -> [Data] {
        lock.withLock {
            recordedBodies[url.absoluteString] ?? []
        }
    }
}

/// @unchecked Sendable justification: URLProtocol is Foundation class infrastructure and this
/// test double has no mutable instance state outside the locked shared test store.
final class ResponsesTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = ResponsesTestURLProtocolState()

    static func register(
        url: URL,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        state.register(url: url, handler: handler)
    }

    static func unregister(url: URL) {
        state.unregister(url: url)
    }

    static func recordedBody(for url: URL) throws -> [String: Any] {
        guard let data = state.recordedBody(for: url) else {
            throw ResponsesTestHelperError.missingRecordedBody(url)
        }
        return try decodeJSONObject(from: data)
    }

    static func recordedBodies(for url: URL) throws -> [[String: Any]] {
        try state.recordedBodies(for: url).map {
            try decodeJSONObject(from: $0)
        }
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
        let request = request

        guard let handler = Self.state.handler(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            if let body = Self.requestBody(from: request) {
                Self.state.recordBody(body, for: url)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead <= 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return data.isEmpty ? nil : data
    }
}

struct ResponsesTestHTTPResponse {
    let statusCode: Int
    let body: Data
    let headers: [String: String]

    init(
        statusCode: Int = 200,
        body: Data,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }
}

/// @unchecked Sendable justification: response sequencing is shared across URLProtocol callbacks
/// and NSLock serializes all access to the queued payloads.
final class ResponsesTestResponseSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [ResponsesTestHTTPResponse]
    private var index = 0

    init(payloads: [Data]) {
        responses = payloads.map { ResponsesTestHTTPResponse(body: $0) }
    }

    init(responses: [ResponsesTestHTTPResponse]) {
        self.responses = responses
    }

    func nextResponse(url: URL) throws -> (HTTPURLResponse, Data) {
        try lock.withLock {
            guard index < responses.count else {
                throw URLError(.badServerResponse)
            }
            let queuedResponse = responses[index]
            index += 1
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: queuedResponse.statusCode,
                httpVersion: nil,
                headerFields: queuedResponse.headers
            ) else {
                throw URLError(.badServerResponse)
            }
            return (response, queuedResponse.body)
        }
    }
}

extension ResponsesAPIClient {
    func setLastResponseId(_ id: String?) {
        lastResponseId = id
    }

    func setLastMessageCount(_ count: Int) {
        lastMessageCount = count
    }

    func setLastPrefixSignature(_ signature: Data) {
        lastPrefixSignature = signature
    }

    func setCursorState(
        responseId: String,
        messages: [ChatMessage]
    ) {
        lastResponseId = responseId
        lastMessageCount = messages.count
        lastPrefixSignature = prefixSignature(messages)
    }
}
