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
    func generateWithManifestMP3ByteRangesAreNilAndEncodingPreserved() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)

        let result = try await client.generateWithManifest(text: "First sentence. Second sentence.")
        #expect(!result.manifest.isEmpty)
        for entry in result.manifest {
            #expect(entry.encoding.format == .mp3)
            #expect(entry.encoding.mimeType == "audio/mpeg")
            #expect(entry.timing.byteRangeInConcatenatedAudio == nil)
            #expect(entry.timing.durationSeconds == nil)
        }
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
