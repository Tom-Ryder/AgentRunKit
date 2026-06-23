@testable import AgentRunKit
import Foundation
import Testing

private let sixSentences =
    "First sentence. Second sentence. Third sentence. Fourth sentence. Fifth sentence. Sixth sentence."

private func wavConfig(maxChunkCharacters: Int = 20) -> TTSProviderConfig {
    TTSProviderConfig(maxChunkCharacters: maxChunkCharacters, defaultVoice: "alloy", defaultFormat: .wav)
}

private func segment(
    index: Int,
    total: Int,
    encoding: TTSAudioEncoding = TTSAudioEncoding(.wav),
    audio: Data = Data("x".utf8)
) -> TTSSegment {
    TTSSegment(
        chunk: TTSChunk(index: index, total: total, text: "t\(index)", sourceRange: index ..< (index + 1)),
        encoding: encoding,
        timing: .uncomputed,
        audio: audio
    )
}

private func expectInvalidConfiguration(
    _ body: () throws -> some Any,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        _ = try body()
        Issue.record("expected TTSError.invalidConfiguration, no error thrown", sourceLocation: sourceLocation)
    } catch let error as TTSError {
        guard case .invalidConfiguration = error else {
            Issue.record("expected TTSError.invalidConfiguration, got \(error)", sourceLocation: sourceLocation)
            return
        }
    } catch {
        Issue.record("expected TTSError, got \(error)", sourceLocation: sourceLocation)
    }
}

struct TTSPartialBatchTests {
    @Test
    func concurrentMidPlanFailurePreservesCompletedAndNamesFailedIndices() async throws {
        let failure = TransportError.httpError(statusCode: 500, body: "fail")
        let provider = MockTTSProvider(
            config: wavConfig(),
            responses: [1: .failure(failure), 3: .failure(failure)],
            generateDelay: .milliseconds(5)
        )
        let client = TTSClient(provider: provider, maxConcurrent: 4)

        let result = try await client.generateBatch(text: sixSentences)

        #expect(result.total == 6)
        #expect(result.completedIndices == [0, 2, 4, 5])
        #expect(result.failedIndices == [1, 3])
        #expect(result.failedChunks.map(\.index) == [1, 3])
        #expect(result.missingIndices.isEmpty)
        #expect(!result.isComplete)
        for failed in result.failures {
            #expect(failed.error == failure)
            #expect(!failed.text.isEmpty)
        }
    }

    @Test
    func existingThrowingPathStopsLaunchingAfterFirstFailure() async {
        let provider = MockTTSProvider(
            config: wavConfig(),
            responses: [2: .failure(TransportError.httpError(statusCode: 500, body: "fail"))]
        )
        let client = TTSClient(provider: provider, maxConcurrent: 1)

        await #expect(throws: TTSError.self) {
            _ = try await client.generateWithManifest(text: sixSentences)
        }

        let calls = await provider.getCallCount()
        #expect(calls == 3)
    }

    @Test
    func generateChunksReRunsOnlyTheGivenChunks() async throws {
        let failure = TransportError.httpError(statusCode: 500, body: "fail")
        let failingProvider = MockTTSProvider(config: wavConfig(), responses: [2: .failure(failure)])
        let batch = try await TTSClient(provider: failingProvider).generateBatch(text: sixSentences)
        #expect(batch.failedIndices == [2])

        let retryProvider = MockTTSProvider(config: wavConfig())
        let retry = try await TTSClient(provider: retryProvider).generate(chunks: batch.failedChunks)

        let retried = await retryProvider.getCalls()
        #expect(retried.keys.sorted() == [2])
        let merged = try batch.merging(retry)
        #expect(merged.isComplete)
        #expect(merged.completedIndices == [0, 1, 2, 3, 4, 5])
    }

    @Test
    func rawConcatRecoveryReproducesAnUninterruptedRun() async throws {
        let golden = try await TTSClient(provider: MockTTSProvider(config: wavConfig()))
            .generateWithManifest(text: sixSentences)

        let failure = TransportError.httpError(statusCode: 500, body: "fail")
        let batchClient = TTSClient(provider: MockTTSProvider(config: wavConfig(), responses: [2: .failure(failure)]))
        let batch = try await batchClient.generateBatch(text: sixSentences)

        let retryClient = TTSClient(provider: MockTTSProvider(config: wavConfig()))
        let merged = try await batch.merging(retryClient.generate(chunks: batch.failedChunks))
        let recovered = try retryClient.concatenate(segments: merged.completedSegments)

        #expect(recovered.audio == golden.audio)
        #expect(recovered.manifest == golden.manifest)
    }

    @Test
    func pcmStitchRecoveryReproducesAnUninterruptedRun() async throws {
        let policy = TTSStitchPolicy(targetCharacters: 15, sentencePause: .milliseconds(100))
        let goldenClient = TTSClient(
            provider: EncodingAwarePCMProvider(maxChunkCharacters: 200, dataFactory: alignedPCMData(for:))
        )
        let golden = try await goldenClient.generateWithManifest(text: sixSentences, stitch: policy)

        let failure = TransportError.httpError(statusCode: 500, body: "fail")
        let batchClient = TTSClient(provider: EncodingAwarePCMProvider(
            maxChunkCharacters: 200,
            responses: [1: .failure(failure)],
            dataFactory: alignedPCMData(for:)
        ))
        let batch = try await batchClient.generateBatch(text: sixSentences, stitch: policy)
        #expect(batch.failedIndices == [1])

        let retryClient = TTSClient(
            provider: EncodingAwarePCMProvider(maxChunkCharacters: 200, dataFactory: alignedPCMData(for:))
        )
        let merged = try await batch.merging(retryClient.generate(chunks: batch.failedChunks))
        let recovered = try retryClient.stitch(segments: merged.completedSegments, policy: policy)

        #expect(recovered.audio == golden.audio)
        #expect(recovered.manifest == golden.manifest)
    }

    @Test
    func loudnessStitchRecoveryReDerivesAndReproducesTheGoldenProgram() async throws {
        let policy = TTSStitchPolicy(targetCharacters: 15, loudness: TTSLoudnessMatch())
        let goldenClient = TTSClient(
            provider: EncodingAwarePCMProvider(maxChunkCharacters: 200, dataFactory: tonePCM(for:))
        )
        let golden = try await goldenClient.generateWithManifest(text: sixSentences, stitch: policy)

        let failure = TransportError.httpError(statusCode: 500, body: "fail")
        let batchClient = TTSClient(provider: EncodingAwarePCMProvider(
            maxChunkCharacters: 200,
            responses: [2: .failure(failure)],
            dataFactory: tonePCM(for:)
        ))
        let batch = try await batchClient.generateBatch(text: sixSentences, stitch: policy)
        #expect(batch.failedIndices == [2])

        let retryClient = TTSClient(
            provider: EncodingAwarePCMProvider(maxChunkCharacters: 200, dataFactory: tonePCM(for:))
        )
        let merged = try await batch.merging(retryClient.generate(chunks: batch.failedChunks))
        let recovered = try retryClient.stitch(segments: merged.completedSegments, policy: policy)

        #expect(recovered.audio == golden.audio)
        #expect(recovered.loudness == golden.loudness)
        #expect(recovered.manifest == golden.manifest)
    }

    @Test
    func generateBatchEmptyTextThrowsEmptyText() async {
        let client = TTSClient(provider: MockTTSProvider(config: wavConfig()))
        await #expect(throws: TTSError.emptyText) {
            _ = try await client.generateBatch(text: "")
        }
        await #expect(throws: TTSError.emptyText) {
            _ = try await client.generateBatch(text: "   \n\t  ")
        }
    }

    @Test
    func generateBatchWrapsNonTransportErrorAsOther() async throws {
        struct CustomError: Error, CustomStringConvertible {
            var description: String {
                "custom failure"
            }
        }
        let provider = MockTTSProvider(
            config: wavConfig(maxChunkCharacters: 1000),
            responses: [0: .failure(CustomError())]
        )
        let result = try await TTSClient(provider: provider).generateBatch(text: "Only one chunk here.")

        #expect(result.completedSegments.isEmpty)
        #expect(result.failedIndices == [0])
        guard case let .other(message) = result.failures[0].error else {
            Issue.record("expected TransportError.other, got \(result.failures[0].error)")
            return
        }
        #expect(message.contains("custom failure"))
    }

    @Test
    func generateBatchCancellationPropagates() async {
        let provider = MockTTSProvider(config: wavConfig(), generateDelay: .seconds(10))
        let client = TTSClient(provider: provider)

        let task = Task { try await client.generateBatch(text: sixSentences) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func multiFailureRecoveryReproducesAnUninterruptedRun() async throws {
        let golden = try await TTSClient(provider: MockTTSProvider(config: wavConfig()))
            .generateWithManifest(text: sixSentences)

        let failure = TransportError.httpError(statusCode: 500, body: "fail")
        let batchClient = TTSClient(provider: MockTTSProvider(
            config: wavConfig(),
            responses: [1: .failure(failure), 3: .failure(failure)]
        ))
        let batch = try await batchClient.generateBatch(text: sixSentences)
        #expect(batch.failedIndices == [1, 3])

        let retryClient = TTSClient(provider: MockTTSProvider(config: wavConfig()))
        let merged = try await batch.merging(retryClient.generate(chunks: batch.failedChunks))
        #expect(merged.isComplete)
        let recovered = try retryClient.concatenate(segments: merged.completedSegments)

        #expect(recovered.audio == golden.audio)
        #expect(recovered.manifest == golden.manifest)
    }

    @Test
    func concatenateRejectsAnEmptySet() {
        let client = TTSClient(provider: MockTTSProvider(config: wavConfig()))
        expectInvalidConfiguration { try client.concatenate(segments: []) }
    }

    @Test
    func concatenateRejectsAHole() {
        let client = TTSClient(provider: MockTTSProvider(config: wavConfig()))
        let holed = [segment(index: 0, total: 3), segment(index: 2, total: 3)]
        expectInvalidConfiguration { try client.concatenate(segments: holed) }
    }

    @Test
    func concatenateRejectsMixedEncodings() {
        let client = TTSClient(provider: MockTTSProvider(config: wavConfig()))
        let mixed = [
            segment(index: 0, total: 2, encoding: TTSAudioEncoding(.wav)),
            segment(index: 1, total: 2, encoding: TTSAudioEncoding(.mp3)),
        ]
        expectInvalidConfiguration { try client.concatenate(segments: mixed) }
    }

    @Test
    func stitchRejectsNonPCMSegments() {
        let client = TTSClient(provider: MockTTSProvider(config: wavConfig()))
        let wav = [segment(index: 0, total: 1, encoding: TTSAudioEncoding(.wav))]
        expectInvalidConfiguration {
            try client.stitch(segments: wav, policy: TTSStitchPolicy(sentencePause: .milliseconds(10)))
        }
    }
}

struct TTSBatchResultTests {
    @Test
    func sparseResultReportsMissingIndices() {
        let result = TTSBatchResult(
            total: 5,
            completedSegments: [segment(index: 0, total: 5), segment(index: 2, total: 5)],
            failures: [TTSChunkFailure(
                chunk: TTSChunk(index: 4, total: 5, text: "t4", sourceRange: 4 ..< 5),
                encoding: TTSAudioEncoding(.wav),
                error: .invalidResponse
            )]
        )

        #expect(result.completedIndices == [0, 2])
        #expect(result.failedIndices == [4])
        #expect(result.missingIndices == [1, 3])
        #expect(!result.isComplete)
    }

    @Test
    func completeResultIsComplete() {
        let result = TTSBatchResult(
            total: 2,
            completedSegments: [segment(index: 1, total: 2), segment(index: 0, total: 2)],
            failures: []
        )
        #expect(result.completedIndices == [0, 1])
        #expect(result.missingIndices.isEmpty)
        #expect(result.isComplete)
    }

    @Test
    func mergingFillsAFailedIndex() throws {
        let original = TTSBatchResult(
            total: 2,
            completedSegments: [segment(index: 0, total: 2)],
            failures: [TTSChunkFailure(
                chunk: TTSChunk(index: 1, total: 2, text: "t1", sourceRange: 1 ..< 2),
                encoding: TTSAudioEncoding(.wav),
                error: .invalidResponse
            )]
        )
        let retry = TTSBatchResult(total: 2, completedSegments: [segment(index: 1, total: 2)], failures: [])

        let merged = try original.merging(retry)
        #expect(merged.isComplete)
        #expect(merged.completedIndices == [0, 1])
    }

    @Test
    func mergingRejectsOverwritingACompletedChunk() {
        let original = TTSBatchResult(
            total: 2,
            completedSegments: [segment(index: 0, total: 2), segment(index: 1, total: 2)],
            failures: []
        )
        let retry = TTSBatchResult(total: 2, completedSegments: [segment(index: 0, total: 2)], failures: [])
        #expect(throws: TTSError.self) {
            _ = try original.merging(retry)
        }
    }

    @Test
    func mergingRejectsATotalMismatch() {
        let original = TTSBatchResult(total: 2, completedSegments: [segment(index: 0, total: 2)], failures: [])
        let retry = TTSBatchResult(total: 3, completedSegments: [segment(index: 1, total: 3)], failures: [])
        #expect(throws: TTSError.self) {
            _ = try original.merging(retry)
        }
    }

    @Test
    func mergingRejectsAMismatchedRetryChunk() {
        let original = TTSBatchResult(
            total: 2,
            completedSegments: [segment(index: 0, total: 2)],
            failures: [TTSChunkFailure(
                chunk: TTSChunk(index: 1, total: 2, text: "original", sourceRange: 1 ..< 2),
                encoding: TTSAudioEncoding(.wav),
                error: .invalidResponse
            )]
        )
        let mismatched = TTSBatchResult(
            total: 2,
            completedSegments: [TTSSegment(
                chunk: TTSChunk(index: 1, total: 2, text: "different", sourceRange: 5 ..< 9),
                encoding: TTSAudioEncoding(.wav),
                timing: .uncomputed,
                audio: Data("x".utf8)
            )],
            failures: []
        )
        #expect(throws: TTSError.self) {
            _ = try original.merging(mismatched)
        }
    }

    @Test
    func mergingRejectsARetryThatFailsACompletedChunk() {
        let original = TTSBatchResult(
            total: 2,
            completedSegments: [segment(index: 0, total: 2), segment(index: 1, total: 2)],
            failures: []
        )
        let retry = TTSBatchResult(
            total: 2,
            completedSegments: [],
            failures: [TTSChunkFailure(
                chunk: TTSChunk(index: 1, total: 2, text: "t1", sourceRange: 1 ..< 2),
                encoding: TTSAudioEncoding(.wav),
                error: .invalidResponse
            )]
        )
        #expect(throws: TTSError.self) {
            _ = try original.merging(retry)
        }
    }
}
