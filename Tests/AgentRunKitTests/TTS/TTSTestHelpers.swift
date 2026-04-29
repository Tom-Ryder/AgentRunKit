@testable import AgentRunKit
import Foundation

struct MockProviderCall: Equatable {
    let text: String
    let voice: String
    let options: TTSOptions
    let context: TTSChunkContext
}

actor MockTTSProvider: TTSProvider {
    let config: TTSProviderConfig
    private var totalCallCount = 0
    private var responses: [Int: Result<Data, any Error>]
    private var callsByChunk: [Int: MockProviderCall] = [:]
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

    func generate(
        text: String,
        voice: String,
        options: TTSOptions,
        context: TTSChunkContext
    ) async throws -> Data {
        totalCallCount += 1
        let chunkIndex = context.chunk.index
        callsByChunk[chunkIndex] = MockProviderCall(
            text: text,
            voice: voice,
            options: options,
            context: context
        )

        if let delay = generateDelay {
            try await Task.sleep(for: delay)
        }

        if let result = responses[chunkIndex] {
            return try result.get()
        }
        return dataFactory(text)
    }

    func getCallCount() -> Int {
        totalCallCount
    }

    func getCall(forChunk index: Int) -> MockProviderCall? {
        callsByChunk[index]
    }

    func getCalls() -> [Int: MockProviderCall] {
        callsByChunk
    }

    func getVoicesInChunkOrder() -> [String] {
        callsByChunk.keys.sorted().compactMap { callsByChunk[$0]?.voice }
    }
}

actor ReverseDelayProvider: TTSProvider {
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

    func generate(
        text: String,
        voice _: String,
        options _: TTSOptions,
        context _: TTSChunkContext
    ) async throws -> Data {
        let index = callCount
        callCount += 1
        try await Task.sleep(for: delayPerChunk * (totalChunks - index))
        return Data(text.utf8)
    }
}

actor ConcurrencyTracker: TTSProvider {
    let config: TTSProviderConfig
    private let wrapped: MockTTSProvider
    private var currentConcurrent = 0
    private var peakConcurrent = 0

    init(wrapped: MockTTSProvider) {
        config = wrapped.config
        self.wrapped = wrapped
    }

    func generate(
        text: String,
        voice: String,
        options: TTSOptions,
        context: TTSChunkContext
    ) async throws -> Data {
        currentConcurrent += 1
        if currentConcurrent > peakConcurrent {
            peakConcurrent = currentConcurrent
        }

        let data = try await wrapped.generate(
            text: text,
            voice: voice,
            options: options,
            context: context
        )

        currentConcurrent -= 1
        return data
    }

    func getPeakConcurrent() -> Int {
        peakConcurrent
    }
}

func wrapInMP3Metadata(_ text: String) -> Data {
    var data = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    data.append(Data(text.utf8))
    data.append(contentsOf: [0x54, 0x41, 0x47])
    data.append(contentsOf: [UInt8](repeating: 0x00, count: 125))
    return data
}
