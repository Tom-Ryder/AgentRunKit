import Foundation
import Testing

struct HTTPTestURLProtocolTests {
    @Test
    func concurrentSessionsKeepRegistrationsBodiesAndResponsesIsolated() async throws {
        let sequenceURL = try #require(URL(string: "https://concurrent-http-\(UUID().uuidString).test"))
        let payloads = (0 ..< 8).map { Data("response-\($0)".utf8) }
        let sequence = HTTPTestResponseSequence(payloads: payloads)
        HTTPTestURLProtocol.register(url: sequenceURL) { _ in try sequence.nextResponse(url: sequenceURL) }
        defer { HTTPTestURLProtocol.unregister(url: sequenceURL) }

        let responses = try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    let url = sequenceURL.appendingPathComponent("constant-\(index)")
                    let session = URLSession(configuration: HTTPTestURLProtocol.configuration())
                    defer { session.invalidateAndCancel() }
                    let responseBody = Data("constant-response-\(index)".utf8)
                    HTTPTestURLProtocol.register(url: url, response: HTTPTestResponse(body: responseBody))
                    defer { HTTPTestURLProtocol.unregister(url: url) }

                    for turn in 0 ..< 2 {
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.httpBody = Data("constant-\(index)-\(turn)".utf8)
                        let (data, response) = try await session.data(for: request)
                        #expect(data == responseBody)
                        #expect(response.url == url)
                    }
                    #expect(HTTPTestURLProtocol.recordedBodyData(for: url) == [
                        Data("constant-\(index)-0".utf8), Data("constant-\(index)-1".utf8)
                    ])

                    var request = URLRequest(url: sequenceURL)
                    request.httpMethod = "POST"
                    request.httpBody = Data("sequence-\(index)".utf8)
                    let (data, response) = try await session.data(for: request)
                    #expect(response.url == sequenceURL)
                    return data
                }
            }
            var responses: [Data] = []
            for try await response in group {
                responses.append(response)
            }
            return responses
        }

        #expect(responses.count == 8)
        #expect(Set(responses) == Set(payloads))
        let bodies = HTTPTestURLProtocol.recordedBodyData(for: sequenceURL)
        #expect(bodies.count == 8)
        #expect(Set(bodies) == Set((0 ..< 8).map { Data("sequence-\($0)".utf8) }))
        for index in 0 ..< 8 {
            #expect(HTTPTestURLProtocol.recordedBodyData(
                for: sequenceURL.appendingPathComponent("constant-\(index)")
            ).isEmpty)
        }
    }

    @Test
    func sequencesExhaustAndUnregisterClearsCapturedBodies() async throws {
        let url = try #require(URL(string: "https://sequence-http-\(UUID().uuidString).test"))
        let session = URLSession(configuration: HTTPTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let sequence = HTTPTestResponseSequence(responses: [
            HTTPTestResponse(statusCode: 202, body: Data("first".utf8), headers: ["X-Order": "first"]),
            HTTPTestResponse(statusCode: 206, body: Data("second".utf8), headers: ["X-Order": "second"])
        ])
        HTTPTestURLProtocol.register(url: url) { _ in try sequence.nextResponse(url: url) }
        defer { HTTPTestURLProtocol.unregister(url: url) }

        for (body, status) in [("first", 202), ("second", 206)] {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            let (data, response) = try await session.data(for: request)
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(data == Data(body.utf8))
            #expect(httpResponse.statusCode == status)
            #expect(httpResponse.value(forHTTPHeaderField: "X-Order") == body)
        }
        #expect(HTTPTestURLProtocol.recordedBodyData(for: url) == [Data("first".utf8), Data("second".utf8)])
        await #expect {
            _ = try await session.data(from: url)
        } throws: { error in
            (error as? URLError)?.code == .badServerResponse
        }

        HTTPTestURLProtocol.unregister(url: url)
        #expect(HTTPTestURLProtocol.recordedBodyData(for: url).isEmpty)
        await #expect {
            _ = try await session.data(from: url)
        } throws: { error in
            (error as? URLError)?.code == .unsupportedURL
        }

        HTTPTestURLProtocol.register(url: url, response: HTTPTestResponse(body: Data("replacement".utf8)))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("replacement request".utf8)
        let (data, _) = try await session.data(for: request)
        #expect(data == Data("replacement".utf8))
        #expect(HTTPTestURLProtocol.recordedBodyData(for: url) == [Data("replacement request".utf8)])
    }

    @Test(arguments: BodyStreamFailure.allCases)
    func bodyStreamFailuresPropagateWithoutRecordingPartialBytes(failure: BodyStreamFailure) async throws {
        let url = try #require(URL(string: "https://request-body-\(UUID().uuidString).test"))
        let session = URLSession(configuration: HTTPTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        HTTPTestURLProtocol.register(url: url, response: HTTPTestResponse(body: Data("response".utf8)))
        defer { HTTPTestURLProtocol.unregister(url: url) }
        let stream = FailingRequestBodyStream(failure: failure)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBodyStream = stream

        do {
            _ = try await session.data(for: request)
            Issue.record("Expected request body stream failure")
        } catch let error as URLError {
            #expect(error.code == failure.error.code)
        }
        #expect(stream.streamStatus == .closed)
        #expect(HTTPTestURLProtocol.recordedBodyData(for: url).isEmpty)
    }

    enum BodyStreamFailure: CaseIterable {
        case open, read, openWithoutError, readWithoutError

        var error: URLError {
            switch self {
            case .open: URLError(.cannotOpenFile)
            case .read: URLError(.networkConnectionLost)
            case .openWithoutError, .readWithoutError: URLError(.cannotDecodeRawData)
            }
        }
    }
}

private final class FailingRequestBodyStream: InputStream {
    private let failure: HTTPTestURLProtocolTests.BodyStreamFailure
    private var status = Stream.Status.notOpen
    private var suppliedPrefix = false

    init(failure: HTTPTestURLProtocolTests.BodyStreamFailure) {
        self.failure = failure
        super.init(data: Data())
    }

    override var streamStatus: Stream.Status {
        status
    }

    override var hasBytesAvailable: Bool {
        status == .open
    }

    override var streamError: (any Error)? {
        guard status == .error else { return nil }
        return switch failure {
        case .open, .read: failure.error
        case .openWithoutError, .readWithoutError: nil
        }
    }

    override func open() {
        status = switch failure {
        case .open, .openWithoutError: .error
        case .read, .readWithoutError: .open
        }
    }

    override func close() {
        status = .closed
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard !suppliedPrefix else {
            status = .error
            return -1
        }
        let prefix = Data("partial body".utf8)
        let count = min(prefix.count, len)
        prefix.copyBytes(to: buffer, count: count)
        suppliedPrefix = true
        return count
    }
}
