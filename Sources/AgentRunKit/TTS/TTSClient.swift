import Foundation

/// Generates speech from text with chunking, concurrent synthesis, and ordered reassembly.
///
/// For a guide on audio workflows, see <doc:MultimodalAndAudio>.
public struct TTSClient<P: TTSProvider>: Sendable {
    public let provider: P
    public let maxConcurrent: Int

    public init(provider: P, maxConcurrent: Int = 4) {
        precondition(maxConcurrent >= 1, "maxConcurrent must be at least 1")
        self.provider = provider
        self.maxConcurrent = maxConcurrent
    }

    public func generate(
        text: String,
        voice: String? = nil,
        options: TTSOptions = TTSOptions()
    ) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TTSError.emptyText
        }
        return try await provider.generate(
            text: trimmed,
            voice: voice ?? provider.config.defaultVoice,
            options: options
        )
    }

    public func stream(
        text: String,
        voice: String? = nil,
        options: TTSOptions = TTSOptions()
    ) -> AsyncThrowingStream<TTSSegment, Error> {
        let resolvedVoice = voice ?? provider.config.defaultVoice
        let chunks = SentenceChunker.chunk(
            text: text,
            maxCharacters: provider.config.maxChunkCharacters
        )

        guard !chunks.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TTSError.emptyText) }
        }

        let provider = provider
        let maxConcurrent = maxConcurrent

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.executeChunks(
                        chunks,
                        voice: resolvedVoice,
                        options: options,
                        provider: provider,
                        maxConcurrent: maxConcurrent,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generateAll(
        text: String,
        voice: String? = nil,
        options: TTSOptions = TTSOptions()
    ) async throws -> Data {
        var segments: [TTSSegment] = []
        for try await segment in stream(text: text, voice: voice, options: options) {
            segments.append(segment)
        }

        let effectiveFormat = options.responseFormat ?? provider.config.defaultFormat
        if effectiveFormat == .mp3 {
            return MP3Concatenator.concatenate(segments.map(\.audio))
        }

        var result = Data()
        for segment in segments {
            result.append(segment.audio)
        }
        return result
    }

    private static func executeChunks(
        _ chunks: [SentenceChunker.Chunk],
        voice: String,
        options: TTSOptions,
        provider: P,
        maxConcurrent: Int,
        continuation: AsyncThrowingStream<TTSSegment, Error>.Continuation
    ) async throws {
        let totalChunks = chunks.count

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var nextToSend = 0
            var nextToYield = 0
            var buffer: [Int: Data] = [:]
            var activeTasks = 0

            while nextToYield < totalChunks {
                while activeTasks < maxConcurrent, nextToSend < totalChunks {
                    let chunkIndex = nextToSend
                    let chunk = chunks[chunkIndex]
                    group.addTask {
                        do {
                            let data = try await provider.generate(
                                text: chunk.text,
                                voice: voice,
                                options: options
                            )
                            return (chunkIndex, data)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as TransportError {
                            throw TTSError.chunkFailed(
                                index: chunkIndex,
                                total: totalChunks,
                                sourceRange: chunk.sourceRange,
                                error
                            )
                        } catch {
                            throw TTSError.chunkFailed(
                                index: chunkIndex,
                                total: totalChunks,
                                sourceRange: chunk.sourceRange,
                                TransportError.other(String(describing: error))
                            )
                        }
                    }
                    nextToSend += 1
                    activeTasks += 1
                }

                guard let (index, data) = try await group.next() else { break }
                activeTasks -= 1
                buffer[index] = data

                while let audio = buffer.removeValue(forKey: nextToYield) {
                    let chunk = chunks[nextToYield]
                    continuation.yield(TTSSegment(
                        index: nextToYield,
                        total: totalChunks,
                        text: chunk.text,
                        sourceRange: chunk.sourceRange,
                        audio: audio
                    ))
                    nextToYield += 1
                }
            }
        }
    }
}
