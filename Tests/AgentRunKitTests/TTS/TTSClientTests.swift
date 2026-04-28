@testable import AgentRunKit
import Foundation
import Testing

private actor MockTTSProvider: TTSProvider {
    let config: TTSProviderConfig
    private var callCount = 0
    private var responses: [Int: Result<Data, any Error>]
    private var receivedVoices: [String] = []
    private var generateDelay: Duration?
    private let dataFactory: @Sendable (String) -> Data

    init(
        config: TTSProviderConfig = TTSProviderConfig(
            maxChunkCharacters: 50,
            defaultVoice: "alloy",
            defaultFormat: .mp3
        ),
        responses: [Int: Result<Data, any Error>] = [:],
        generateDelay: Duration? = nil,
        dataFactory: @Sendable @escaping (String) -> Data = { Data($0.utf8) }
    ) {
        self.config = config
        self.responses = responses
        self.generateDelay = generateDelay
        self.dataFactory = dataFactory
    }

    func generate(text: String, voice: String, options _: TTSOptions) async throws -> Data {
        let index = callCount
        callCount += 1
        receivedVoices.append(voice)

        if let delay = generateDelay {
            try await Task.sleep(for: delay)
        }

        if let result = responses[index] {
            return try result.get()
        }
        return dataFactory(text)
    }

    func getCallCount() -> Int {
        callCount
    }

    func getReceivedVoices() -> [String] {
        receivedVoices
    }
}

private actor ReverseDelayProvider: TTSProvider {
    let config: TTSProviderConfig
    private var callCount = 0
    private let totalChunks: Int
    private let delayPerChunk: Duration

    init(
        totalChunks: Int,
        config: TTSProviderConfig = TTSProviderConfig(
            maxChunkCharacters: 20,
            defaultVoice: "alloy",
            defaultFormat: .wav
        ),
        delayPerChunk: Duration = .milliseconds(20)
    ) {
        self.totalChunks = totalChunks
        self.config = config
        self.delayPerChunk = delayPerChunk
    }

    func generate(text: String, voice _: String, options _: TTSOptions) async throws -> Data {
        let index = callCount
        callCount += 1
        try await Task.sleep(for: delayPerChunk * (totalChunks - index))
        return Data(text.utf8)
    }
}

private actor ConcurrencyTracker: TTSProvider {
    let config: TTSProviderConfig
    private let wrapped: MockTTSProvider
    private var currentConcurrent = 0
    private var peakConcurrent = 0

    init(wrapped: MockTTSProvider) {
        config = wrapped.config
        self.wrapped = wrapped
    }

    func generate(text: String, voice: String, options: TTSOptions) async throws -> Data {
        currentConcurrent += 1
        if currentConcurrent > peakConcurrent {
            peakConcurrent = currentConcurrent
        }

        let data = try await wrapped.generate(text: text, voice: voice, options: options)

        currentConcurrent -= 1
        return data
    }

    func getPeakConcurrent() -> Int {
        peakConcurrent
    }
}

private func wrapInMP3Metadata(_ text: String) -> Data {
    var data = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    data.append(Data(text.utf8))
    data.append(contentsOf: [0x54, 0x41, 0x47])
    data.append(contentsOf: [UInt8](repeating: 0x00, count: 125))
    return data
}

struct TTSClientTests {
    @Test
    func generateDelegatesToProvider() async throws {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)
        let result = try await client.generate(text: "Hello world")
        #expect(result == Data("Hello world".utf8))
    }

    @Test
    func generateWithEmptyTextThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)
        await #expect(throws: TTSError.emptyText) {
            try await client.generate(text: "")
        }
    }

    @Test
    func generateWithWhitespaceOnlyThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)
        await #expect(throws: TTSError.emptyText) {
            try await client.generate(text: "   \n\t  ")
        }
    }

    @Test
    func streamYieldsSegmentsInOrder() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: text) {
            segments.append(segment)
        }

        #expect(segments.count >= 2)
        for (idx, segment) in segments.enumerated() {
            #expect(segment.index == idx)
            #expect(segment.total == segments.count)
        }
    }

    @Test
    func streamYieldsSegmentsInOrderDespiteOutOfOrderCompletion() async throws {
        let provider = ReverseDelayProvider(
            totalChunks: 4,
            config: TTSProviderConfig(maxChunkCharacters: 15, defaultVoice: "alloy", defaultFormat: .wav),
            delayPerChunk: .milliseconds(30)
        )
        let client = TTSClient(provider: provider, maxConcurrent: 4)
        let text = "First sent. Second sent. Third sent. Fourth sent."

        var indices: [Int] = []
        for try await segment in client.stream(text: text) {
            indices.append(segment.index)
        }

        #expect(indices == Array(0 ..< indices.count))
    }

    @Test
    func streamWithEmptyTextThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)

        await #expect(throws: TTSError.emptyText) {
            for try await _ in client.stream(text: "") {}
        }
    }

    @Test
    func streamWithWhitespaceOnlyThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)

        await #expect(throws: TTSError.emptyText) {
            for try await _ in client.stream(text: "   \n\n  ") {}
        }
    }

    @Test
    func generateAllWithEmptyTextThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)

        await #expect(throws: TTSError.emptyText) {
            try await client.generateAll(text: "")
        }
    }

    @Test
    func generateAllConcatenatesSegments() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        var segmentData: [Data] = []
        for try await segment in client.stream(text: text) {
            segmentData.append(segment.audio)
        }
        var expected = Data()
        for segment in segmentData {
            expected.append(segment)
        }

        let result = try await client.generateAll(text: text)
        #expect(result == expected)
    }

    @Test
    func generateAllSingleChunkReturnsProviderData() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)

        let result = try await client.generateAll(text: "Short text.")
        #expect(result == Data("Short text.".utf8))
    }

    @Test
    func providerTransportErrorPropagatesAsChunkFailed() async {
        let error = TransportError.httpError(statusCode: 500, body: "Internal Server Error")
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .mp3),
            responses: [0: .failure(error)]
        )
        let client = TTSClient(provider: provider)

        do {
            for try await _ in client.stream(text: "Hello.") {}
            Issue.record("Expected error")
        } catch let thrown as TTSError {
            guard case let .chunkFailed(index, total, sourceRange, transportError) = thrown else {
                Issue.record("Expected chunkFailed, got \(thrown)")
                return
            }
            #expect(index == 0)
            #expect(total == 1)
            #expect(sourceRange == 0 ..< 6)
            #expect(transportError == error)
        } catch {
            Issue.record("Expected TTSError, got \(error)")
        }
    }

    @Test
    func providerNonTransportErrorWrappedInChunkFailed() async {
        struct CustomError: Error, CustomStringConvertible {
            var description: String {
                "custom failure"
            }
        }
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .mp3),
            responses: [0: .failure(CustomError())]
        )
        let client = TTSClient(provider: provider)

        do {
            for try await _ in client.stream(text: "Hello.") {}
            Issue.record("Expected error")
        } catch let error as TTSError {
            if case let .chunkFailed(index, total, sourceRange, transportError) = error {
                #expect(index == 0)
                #expect(total == 1)
                #expect(sourceRange == 0 ..< 6)
                if case let .other(message) = transportError {
                    #expect(message.contains("custom failure"))
                } else {
                    Issue.record("Expected TransportError.other, got \(transportError)")
                }
            } else {
                Issue.record("Expected chunkFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected TTSError, got \(error)")
        }
    }

    @Test
    func chunkFailedReportsCorrectIndexForMidStreamFailure() async {
        let transportError = TransportError.httpError(statusCode: 500, body: "fail")
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav),
            responses: [1: .failure(transportError)]
        )
        let client = TTSClient(provider: provider, maxConcurrent: 1)

        do {
            for try await _ in client.stream(text: "First sentence. Second sentence. Third sentence.") {}
            Issue.record("Expected error")
        } catch let thrown as TTSError {
            guard case let .chunkFailed(index, total, sourceRange, _) = thrown else {
                Issue.record("Expected chunkFailed, got \(thrown)")
                return
            }
            #expect(index == 1)
            #expect(total >= 2)
            #expect(sourceRange.lowerBound > 0)
        } catch {
            Issue.record("Expected TTSError, got \(error)")
        }
    }

    @Test
    func boundedConcurrency() async throws {
        let innerProvider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 10, defaultVoice: "alloy", defaultFormat: .wav),
            generateDelay: .milliseconds(50)
        )
        let tracker = ConcurrencyTracker(wrapped: innerProvider)
        let client = TTSClient(provider: tracker, maxConcurrent: 2)

        let text = "One. Two. Three. Four. Five."
        for try await _ in client.stream(text: text) {}

        let peak = await tracker.getPeakConcurrent()
        #expect(peak == 2)
    }

    @Test
    func voiceDefaultsToProviderConfig() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "shimmer", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        _ = try await client.generate(text: "Hello")

        let voices = await provider.getReceivedVoices()
        #expect(voices == ["shimmer"])
    }

    @Test
    func voiceOverridesProviderDefault() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        _ = try await client.generate(text: "Hello", voice: "nova")

        let voices = await provider.getReceivedVoices()
        #expect(voices == ["nova"])
    }

    @Test
    func generateAllUsesMP3ConcatenationForMP3Format() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        var segmentData: [Data] = []
        for try await segment in client.stream(text: text) {
            segmentData.append(segment.audio)
        }

        let mp3Concatenated = MP3Concatenator.concatenate(segmentData)
        var simpleAppend = Data()
        for data in segmentData {
            simpleAppend.append(data)
        }

        #expect(mp3Concatenated != simpleAppend)
        let result = try await client.generateAll(text: text)
        #expect(result == mp3Concatenated)
    }

    @Test
    func generateAllUsesSimpleAppendForNonMP3Format() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        var segmentData: [Data] = []
        for try await segment in client.stream(text: text) {
            segmentData.append(segment.audio)
        }

        var simpleAppend = Data()
        for data in segmentData {
            simpleAppend.append(data)
        }
        let mp3Concatenated = MP3Concatenator.concatenate(segmentData)

        #expect(simpleAppend != mp3Concatenated)
        let result = try await client.generateAll(text: text)
        #expect(result == simpleAppend)
    }

    @Test
    func formatOverrideInOptionsUsedForConcatenation() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)
        let options = TTSOptions(responseFormat: .wav)
        let text = "First sentence. Second sentence."

        var segmentData: [Data] = []
        for try await segment in client.stream(text: text, options: options) {
            segmentData.append(segment.audio)
        }

        var simpleAppend = Data()
        for data in segmentData {
            simpleAppend.append(data)
        }
        let mp3Concatenated = MP3Concatenator.concatenate(segmentData)

        #expect(simpleAppend != mp3Concatenated)
        let result = try await client.generateAll(text: text, options: options)
        #expect(result == simpleAppend)
    }

    @Test
    func streamCancellationPropagatesCancellationError() async {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 10, defaultVoice: "alloy", defaultFormat: .mp3),
            generateDelay: .seconds(10)
        )
        let client = TTSClient(provider: provider)

        let task = Task {
            for try await _ in client.stream(text: "First sentence. Second sentence.") {}
            try Task.checkCancellation()
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError but stream completed successfully")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func segmentTextAndRangeMatchChunkerOutput() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: text) {
            segments.append(segment)
        }

        let expected = SentenceChunker.chunk(text: text, maxCharacters: 20)
        #expect(segments.map(\.text) == expected.map(\.text))
        #expect(segments.map(\.sourceRange) == expected.map(\.sourceRange))
    }

    @Test
    func segmentSourceRangesAreLeftToRightMonotonic() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 25, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        var ranges: [Range<Int>] = []
        for try await segment in client.stream(text: text) {
            ranges.append(segment.sourceRange)
        }

        let utf8 = Array(text.utf8)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == utf8.count)
        #expect(ranges.allSatisfy { !$0.isEmpty })
        for index in 1 ..< ranges.count {
            #expect(ranges[index].lowerBound >= ranges[index - 1].upperBound)
        }
    }

    @Test
    func audioMatchesTextUnderReverseCompletion() async throws {
        let provider = ReverseDelayProvider(
            totalChunks: 4,
            config: TTSProviderConfig(maxChunkCharacters: 15, defaultVoice: "alloy", defaultFormat: .wav),
            delayPerChunk: .milliseconds(20)
        )
        let client = TTSClient(provider: provider, maxConcurrent: 4)
        let text = "First sent. Second sent. Third sent. Fourth sent."

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: text) {
            segments.append(segment)
        }

        #expect(segments.count == 4)
        for segment in segments {
            #expect(Data(segment.text.utf8) == segment.audio)
        }
        #expect(segments.map(\.index) == Array(0 ..< segments.count))
    }
}
