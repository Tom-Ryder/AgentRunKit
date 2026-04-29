@testable import AgentRunKit
import Foundation
import Testing

private func manifestTestPCMData(for text: String) -> Data {
    let marker = UInt8(text.utf8.reduce(0) { ($0 + Int($1)) % 251 })
    return Data(repeating: marker, count: text.utf8.count * 3)
}

struct TTSClientManifestTests {
    @Test
    func generateWithManifestProducesEntryPerChunkInOrder() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .pcm)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        let result = try await client.generateWithManifest(text: text)
        let plan = client.chunks(for: text)

        #expect(result.manifest.count == plan.count)
        #expect(result.manifest.map(\.chunk) == plan)
        #expect(result.manifest.allSatisfy { $0.encoding.format == .pcm })
    }

    @Test
    func generateWithManifestPCMByteRangesAreCumulativeAndContiguous() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .pcm)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        let result = try await client.generateWithManifest(text: text)

        var cursor = 0
        for entry in result.manifest {
            let range = try #require(entry.timing.byteRangeInConcatenatedAudio)
            #expect(range.lowerBound == cursor)
            #expect(range.upperBound > range.lowerBound)
            cursor = range.upperBound
        }
        #expect(cursor == result.audio.count)
    }

    @Test
    func generateWithManifestPCMDurationFieldsRemainNilUntilEncodingMetadataExists() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .pcm)
        )
        let client = TTSClient(provider: provider)

        let result = try await client.generateWithManifest(text: "First sentence. Second sentence.")
        for entry in result.manifest {
            #expect(entry.timing.durationSeconds == nil)
        }
    }

    @Test
    func generateWithManifestMP3ByteRangesArePopulatedAndEncodingPreserved() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)

        let result = try await client.generateWithManifest(text: "First sentence. Second sentence.")
        #expect(!result.manifest.isEmpty)

        var cursor = 0
        for entry in result.manifest {
            #expect(entry.encoding.format == .mp3)
            #expect(entry.encoding.mimeType == "audio/mpeg")
            let range = try #require(entry.timing.byteRangeInConcatenatedAudio)
            #expect(range.lowerBound == cursor)
            cursor = range.upperBound
            #expect(entry.timing.durationSeconds == nil)
        }
        #expect(cursor == result.audio.count)
    }

    @Test
    func generateWithManifestMP3RoutesAudioThroughMP3Concatenator() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        var streamedAudio: [Data] = []
        for try await segment in client.stream(text: text) {
            streamedAudio.append(segment.audio)
        }

        let result = try await client.generateWithManifest(text: text)
        let stripped = MP3Concatenator.concatenate(streamedAudio)
        let rawAppend = streamedAudio.reduce(into: Data()) { $0.append($1) }
        #expect(result.audio == stripped)
        #expect(result.audio != rawAppend)
    }

    @Test
    func generateWithManifestUsesResolvedEncodingFormatForConcatenation() async throws {
        let provider = PCMRequestResolvedMP3Provider()
        let client = TTSClient(provider: provider)
        let result = try await client.generateWithManifest(text: "First sentence. Second sentence.")

        let chunkAudio = result.manifest.map { wrapInMP3Metadata($0.chunk.text) }
        let stripped = MP3Concatenator.concatenate(chunkAudio)
        let rawAppend = chunkAudio.reduce(into: Data()) { $0.append($1) }

        #expect(!result.manifest.isEmpty)
        #expect(result.audio == stripped)
        #expect(result.audio != rawAppend)
        for entry in result.manifest {
            #expect(entry.encoding.format == .mp3)
            #expect(entry.timing.byteRangeInConcatenatedAudio != nil)
            #expect(entry.timing.durationSeconds == nil)
        }
    }

    @Test
    func generateWithManifestMP3RangesShrinkInteriorSegmentsByID3Stripping() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        var streamedAudio: [Data] = []
        for try await segment in client.stream(text: text) {
            streamedAudio.append(segment.audio)
        }
        try #require(streamedAudio.count >= 3)

        let result = try await client.generateWithManifest(text: text)
        try #require(result.manifest.count == streamedAudio.count)

        let header = mp3WrapperHeader.count
        let tail = mp3WrapperTail.count

        let firstRange = try #require(result.manifest[0].timing.byteRangeInConcatenatedAudio)
        #expect(firstRange.count == streamedAudio[0].count - tail)

        for index in 1 ..< (streamedAudio.count - 1) {
            let range = try #require(result.manifest[index].timing.byteRangeInConcatenatedAudio)
            #expect(range.count == streamedAudio[index].count - header - tail)
        }

        let lastIndex = streamedAudio.count - 1
        let lastRange = try #require(result.manifest[lastIndex].timing.byteRangeInConcatenatedAudio)
        #expect(lastRange.count == streamedAudio[lastIndex].count - header)
    }

    @Test
    func generateWithManifestWAVByteRangesAreNilAndEncodingPreserved() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)

        let result = try await client.generateWithManifest(text: "First sentence. Second sentence.")
        #expect(!result.manifest.isEmpty)
        for entry in result.manifest {
            #expect(entry.encoding.format == .wav)
            #expect(entry.encoding.mimeType == "audio/wav")
            #expect(entry.timing.byteRangeInConcatenatedAudio == nil)
            #expect(entry.timing.durationSeconds == nil)
        }
    }

    @Test
    func generateWithManifestPCMByteRangesSliceConcatenatedAudioToSegmentBytes() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .pcm),
            dataFactory: manifestTestPCMData
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        let result = try await client.generateWithManifest(text: text)

        #expect(result.manifest.count >= 2)
        for entry in result.manifest {
            let range = try #require(entry.timing.byteRangeInConcatenatedAudio)
            let expectedLength = entry.chunk.text.utf8.count * 3
            #expect(range.count == expectedLength)
            let slice = result.audio.subdata(in: range)
            let expected = manifestTestPCMData(for: entry.chunk.text)
            #expect(slice == expected)
        }
    }

    @Test
    func generateWithManifestHonorsResponseFormatOverride() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        let options = TTSOptions(responseFormat: .pcm)

        let result = try await client.generateWithManifest(
            text: "First sentence. Second sentence.",
            options: options
        )

        #expect(!result.manifest.isEmpty)
        for entry in result.manifest {
            #expect(entry.encoding.format == .pcm)
            #expect(entry.timing.byteRangeInConcatenatedAudio != nil)
        }
    }

    @Test
    func generateAllReturnsManifestAudioForPCM() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .pcm)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        let viaGenerateAll = try await client.generateAll(text: text)
        let viaManifest = try await client.generateWithManifest(text: text)
        #expect(viaGenerateAll == viaManifest.audio)
    }

    @Test
    func generateAllReturnsManifestAudioForMP3() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        let viaGenerateAll = try await client.generateAll(text: text)
        let viaManifest = try await client.generateWithManifest(text: text)
        #expect(viaGenerateAll == viaManifest.audio)
    }

    @Test
    func generateWithManifestEmptyTextThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)
        await #expect(throws: TTSError.emptyText) {
            try await client.generateWithManifest(text: "")
        }
    }

    @Test
    func streamSegmentsKeepUncomputedTimingEvenForPCMFormat() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .pcm)
        )
        let client = TTSClient(provider: provider)

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: "First sentence. Second sentence.") {
            segments.append(segment)
        }
        #expect(!segments.isEmpty)
        for segment in segments {
            #expect(segment.timing == .uncomputed)
        }
    }

    @Test
    func generateWithManifestPCMByteRangesPreservedUnderReverseCompletion() async throws {
        let provider = ReverseDelayProvider(
            totalChunks: 4,
            config: TTSProviderConfig(maxChunkCharacters: 15, defaultVoice: "alloy", defaultFormat: .pcm),
            delayPerChunk: .milliseconds(20)
        )
        let client = TTSClient(provider: provider, maxConcurrent: 4)
        let text = "First sent. Second sent. Third sent. Fourth sent."

        let result = try await client.generateWithManifest(text: text)
        #expect(result.manifest.count == 4)

        var cursor = 0
        for (entryIndex, entry) in result.manifest.enumerated() {
            #expect(entry.chunk.index == entryIndex)
            let range = try #require(entry.timing.byteRangeInConcatenatedAudio)
            #expect(range.lowerBound == cursor)
            cursor = range.upperBound
        }
        #expect(cursor == result.audio.count)
    }

    @Test
    func generateWithManifestPropagatesChunkFailure() async {
        let transportError = TransportError.httpError(statusCode: 500, body: "fail")
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .pcm),
            responses: [1: .failure(transportError)]
        )
        let client = TTSClient(provider: provider, maxConcurrent: 1)

        do {
            _ = try await client.generateWithManifest(
                text: "First sentence. Second sentence. Third sentence."
            )
            Issue.record("Expected TTSError.chunkFailed")
        } catch let error as TTSError {
            guard case let .chunkFailed(index, _, _, _) = error else {
                Issue.record("Expected chunkFailed, got \(error)")
                return
            }
            #expect(index == 1)
        } catch {
            Issue.record("Expected TTSError, got \(type(of: error)): \(error)")
        }
    }
}

private struct PCMEncodingScenario {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
}

private struct EncodingAwarePCMProvider: TTSProvider {
    let config: TTSProviderConfig
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let dataFactory: @Sendable (String) -> Data

    init(
        sampleRate: Int = 24000,
        channels: Int = 1,
        bitsPerSample: Int = 16,
        maxChunkCharacters: Int = 20,
        defaultVoice: String = "alloy",
        dataFactory: @Sendable @escaping (String) -> Data = manifestTestPCMData(for:)
    ) {
        config = TTSProviderConfig(
            maxChunkCharacters: maxChunkCharacters,
            defaultVoice: defaultVoice,
            defaultFormat: .pcm
        )
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.dataFactory = dataFactory
    }

    func resolvedEncoding(for format: TTSAudioFormat, options _: TTSOptions) -> TTSAudioEncoding {
        switch format {
        case .pcm:
            TTSAudioEncoding(format, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample)
        case .mp3, .opus, .aac, .flac, .wav:
            TTSAudioEncoding(format)
        }
    }

    func generate(
        text: String,
        voice _: String,
        options _: TTSOptions,
        context _: TTSChunkContext
    ) async -> Data {
        dataFactory(text)
    }
}

struct TTSClientPCMDurationTests {
    @Test
    func generateWithManifestPCMDurationMatchesBytesOverBytesPerSecondWhenEncodingPopulated() async throws {
        let provider = EncodingAwarePCMProvider()
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        let result = try await client.generateWithManifest(text: text)
        let bytesPerSecond = Double(provider.sampleRate * provider.channels * (provider.bitsPerSample / 8))

        #expect(!result.manifest.isEmpty)
        for entry in result.manifest {
            let range = try #require(entry.timing.byteRangeInConcatenatedAudio)
            let duration = try #require(entry.timing.durationSeconds)
            #expect(duration == Double(range.count) / bytesPerSecond)
        }
    }

    @Test
    func generateWithManifestPCMDurationsAreNilWhenProviderUsesDefaultEncoding() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .pcm)
        )
        let client = TTSClient(provider: provider)

        let result = try await client.generateWithManifest(text: "First sentence. Second sentence.")
        #expect(!result.manifest.isEmpty)
        for entry in result.manifest {
            #expect(entry.timing.durationSeconds == nil)
            #expect(entry.encoding.sampleRate == nil)
            #expect(entry.encoding.channels == nil)
            #expect(entry.encoding.bitsPerSample == nil)
        }
    }

    @Test
    func generateWithManifestUnsupportedFormatsReportNilTiming() async throws {
        for format in [TTSAudioFormat.wav, .opus, .flac, .aac] {
            let provider = MockTTSProvider(
                config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: format)
            )
            let client = TTSClient(provider: provider)
            let result = try await client.generateWithManifest(text: "First sentence. Second sentence.")
            #expect(!result.manifest.isEmpty)
            for entry in result.manifest {
                #expect(entry.timing.byteRangeInConcatenatedAudio == nil)
                #expect(entry.timing.durationSeconds == nil)
            }
        }
    }

    @Test
    func generateWithManifestPCMDurationSumsToTotalAudioDuration() async throws {
        let provider = EncodingAwarePCMProvider()
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        let result = try await client.generateWithManifest(text: text)
        let bytesPerSecond = Double(provider.sampleRate * provider.channels * (provider.bitsPerSample / 8))
        let summed = try result.manifest.reduce(0.0) { partial, entry in
            try partial + #require(entry.timing.durationSeconds)
        }
        let expected = Double(result.audio.count) / bytesPerSecond
        #expect(summed == expected)
    }

    @Test
    func generateWithManifestPCMDurationMatchesFormulaFor24BitStereo() async throws {
        let provider = EncodingAwarePCMProvider(sampleRate: 48000, channels: 2, bitsPerSample: 24)
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        let result = try await client.generateWithManifest(text: text)
        let bytesPerSecond = Double(48000 * 2 * 3)

        #expect(!result.manifest.isEmpty)
        for entry in result.manifest {
            let range = try #require(entry.timing.byteRangeInConcatenatedAudio)
            let duration = try #require(entry.timing.durationSeconds)
            #expect(duration == Double(range.count) / bytesPerSecond)
        }
    }

    @Test
    func generateWithManifestPCMDurationIsNilForZeroValuedEncodingFields() async throws {
        let scenarios: [PCMEncodingScenario] = [
            PCMEncodingScenario(sampleRate: 0, channels: 1, bitsPerSample: 16),
            PCMEncodingScenario(sampleRate: 24000, channels: 0, bitsPerSample: 16),
            PCMEncodingScenario(sampleRate: 24000, channels: 1, bitsPerSample: 0)
        ]
        for scenario in scenarios {
            let provider = EncodingAwarePCMProvider(
                sampleRate: scenario.sampleRate,
                channels: scenario.channels,
                bitsPerSample: scenario.bitsPerSample
            )
            let client = TTSClient(provider: provider)
            let result = try await client.generateWithManifest(text: "First sentence.")
            #expect(!result.manifest.isEmpty)
            for entry in result.manifest {
                #expect(entry.timing.durationSeconds == nil)
            }
        }
    }

    @Test
    func generateWithManifestPCMDurationIsNilWhenBitsPerSampleNotByteAligned() async throws {
        for bits in [12, 20] {
            let provider = EncodingAwarePCMProvider(
                sampleRate: 24000,
                channels: 1,
                bitsPerSample: bits
            )
            let client = TTSClient(provider: provider)
            let result = try await client.generateWithManifest(text: "First sentence.")
            #expect(!result.manifest.isEmpty)
            for entry in result.manifest {
                #expect(entry.timing.durationSeconds == nil)
            }
        }
    }

    @Test
    func generateWithManifestPCMDurationIsNilOnIntegerOverflow() async throws {
        let provider = EncodingAwarePCMProvider(
            sampleRate: Int.max / 2,
            channels: 4,
            bitsPerSample: 16
        )
        let client = TTSClient(provider: provider)
        let result = try await client.generateWithManifest(text: "First sentence.")
        #expect(!result.manifest.isEmpty)
        for entry in result.manifest {
            #expect(entry.timing.durationSeconds == nil)
        }
    }
}

private struct PCMRequestResolvedMP3Provider: TTSProvider {
    let config = TTSProviderConfig(
        maxChunkCharacters: 20,
        defaultVoice: "alloy",
        defaultFormat: .pcm
    )

    func resolvedEncoding(for _: TTSAudioFormat, options _: TTSOptions) -> TTSAudioEncoding {
        TTSAudioEncoding(.mp3)
    }

    func generate(
        text: String,
        voice _: String,
        options _: TTSOptions,
        context _: TTSChunkContext
    ) async -> Data {
        wrapInMP3Metadata(text)
    }
}

private struct MP3WithPopulatedAudioMetadataProvider: TTSProvider {
    let config = TTSProviderConfig(
        maxChunkCharacters: 20,
        defaultVoice: "alloy",
        defaultFormat: .mp3
    )

    func resolvedEncoding(for format: TTSAudioFormat, options _: TTSOptions) -> TTSAudioEncoding {
        switch format {
        case .mp3:
            TTSAudioEncoding(format, sampleRate: 44100, channels: 2, bitsPerSample: 16)
        case .pcm, .opus, .aac, .flac, .wav:
            TTSAudioEncoding(format)
        }
    }

    func generate(
        text: String,
        voice _: String,
        options _: TTSOptions,
        context _: TTSChunkContext
    ) async -> Data {
        wrapInMP3Metadata(text)
    }
}

struct TTSClientMP3MetadataDurationTests {
    @Test
    func generateWithManifestMP3DurationStaysNilEvenWhenProviderSuppliesAudioMetadata() async throws {
        let client = TTSClient(provider: MP3WithPopulatedAudioMetadataProvider())
        let result = try await client.generateWithManifest(text: "First sentence. Second sentence.")
        #expect(!result.manifest.isEmpty)
        for entry in result.manifest {
            #expect(entry.encoding.format == .mp3)
            #expect(entry.encoding.sampleRate == 44100)
            #expect(entry.encoding.channels == 2)
            #expect(entry.encoding.bitsPerSample == 16)
            #expect(entry.timing.durationSeconds == nil)
        }
    }
}

private actor RecordingPCMProvider: TTSProvider {
    let config = TTSProviderConfig(
        maxChunkCharacters: 100,
        defaultVoice: "alloy",
        defaultFormat: .pcm
    )
    private(set) var capturedContext: TTSChunkContext?

    nonisolated func resolvedEncoding(
        for format: TTSAudioFormat,
        options _: TTSOptions
    ) -> TTSAudioEncoding {
        switch format {
        case .pcm:
            TTSAudioEncoding(format, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        case .mp3, .opus, .aac, .flac, .wav:
            TTSAudioEncoding(format)
        }
    }

    func generate(
        text: String,
        voice _: String,
        options _: TTSOptions,
        context: TTSChunkContext
    ) async -> Data {
        capturedContext = context
        return Data(text.utf8)
    }
}

struct TTSClientSingleShotEncodingTests {
    @Test
    func generatePropagatesProviderResolvedEncodingMetadataIntoChunkContext() async throws {
        let provider = RecordingPCMProvider()
        let client = TTSClient(provider: provider)
        _ = try await client.generate(text: "Hello world.")
        let captured = await provider.capturedContext
        let context = try #require(captured)
        #expect(context.encoding.format == .pcm)
        #expect(context.encoding.sampleRate == 24000)
        #expect(context.encoding.channels == 1)
        #expect(context.encoding.bitsPerSample == 16)
    }
}
