import Foundation

private enum HTTPTestHelperError: Error {
    case expectedJSONObject
    case missingRecordedBody(URL)
}

func decodeHTTPTestJSONObject(from data: Data) throws -> [String: Any] {
    let json = try JSONSerialization.jsonObject(with: data)
    guard let object = json as? [String: Any] else {
        throw HTTPTestHelperError.expectedJSONObject
    }
    return object
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
final class HTTPTestURLProtocolState: @unchecked Sendable {
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
final class HTTPTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = HTTPTestURLProtocolState()

    static func register(
        url: URL,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        state.register(url: url, handler: handler)
    }

    static func unregister(url: URL) {
        state.unregister(url: url)
    }

    static func recordedBodyData(for url: URL) -> [Data] {
        state.recordedBodies(for: url)
    }

    static func recordedBody(for url: URL) throws -> [String: Any] {
        guard let data = state.recordedBody(for: url) else {
            throw HTTPTestHelperError.missingRecordedBody(url)
        }
        return try decodeHTTPTestJSONObject(from: data)
    }

    static func recordedBodies(for url: URL) throws -> [[String: Any]] {
        try state.recordedBodies(for: url).map {
            try decodeHTTPTestJSONObject(from: $0)
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

struct HTTPTestResponse {
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
final class HTTPTestResponseSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [HTTPTestResponse]
    private var index = 0

    init(payloads: [Data]) {
        responses = payloads.map { HTTPTestResponse(body: $0) }
    }

    init(responses: [HTTPTestResponse]) {
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
