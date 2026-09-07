import Foundation
import Testing

struct HTTPTestURLProtocolTests {
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
