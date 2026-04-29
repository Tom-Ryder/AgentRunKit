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
        let encoding = TTSAudioEncoding(options.responseFormat ?? provider.config.defaultFormat)
        let leadingShift = SentenceChunker.trimByteOffset(in: text)
        let chunk = TTSChunk(
            index: 0,
            total: 1,
            text: trimmed,
            sourceRange: leadingShift ..< (leadingShift + trimmed.utf8.count)
        )
        let context = TTSChunkContext(chunk: chunk, encoding: encoding)
        return try await provider.generate(
            text: trimmed,
            voice: voice ?? provider.config.defaultVoice,
            options: options,
            context: context
        )
    }

    /// The chunk plan this client will use for a given input, without invoking the provider.
    public func chunks(for text: String) -> [TTSChunk] {
        let internalChunks = SentenceChunker.chunk(
            text: text,
            maxCharacters: provider.config.maxChunkCharacters
        )
        return Self.makePublicChunks(internalChunks)
    }

    public func stream(
        text: String,
        voice: String? = nil,
        options: TTSOptions = TTSOptions()
    ) -> AsyncThrowingStream<TTSSegment, Error> {
        let resolvedVoice = voice ?? provider.config.defaultVoice
        let internalChunks = SentenceChunker.chunk(
            text: text,
            maxCharacters: provider.config.maxChunkCharacters
        )

        guard !internalChunks.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TTSError.emptyText) }
        }

        let publicChunks = Self.makePublicChunks(internalChunks)
        let encoding = TTSAudioEncoding(options.responseFormat ?? provider.config.defaultFormat)
        let provider = provider
        let maxConcurrent = maxConcurrent

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.executeChunks(
                        publicChunks,
                        voice: resolvedVoice,
                        options: options,
                        encoding: encoding,
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
        try await generateWithManifest(text: text, voice: voice, options: options).audio
    }

    /// Synthesizes the input and returns concatenated audio plus a per-segment manifest; chunk failure throws.
    public func generateWithManifest(
        text: String,
        voice: String? = nil,
        options: TTSOptions = TTSOptions()
    ) async throws -> TTSConcatenationResult {
        var segments: [TTSSegment] = []
        for try await segment in stream(text: text, voice: voice, options: options) {
            segments.append(segment)
        }

        let effectiveFormat = options.responseFormat ?? provider.config.defaultFormat
        let audio: Data = if effectiveFormat == .mp3 {
            MP3Concatenator.concatenate(segments.map(\.audio))
        } else {
            Self.appendingConcatenation(segments.map(\.audio))
        }

        var manifest: [TTSManifestEntry] = []
        manifest.reserveCapacity(segments.count)
        var pcmCursor = 0
        for segment in segments {
            let timing: TTSSegmentTiming
            if effectiveFormat == .pcm {
                let lower = pcmCursor
                pcmCursor += segment.audio.count
                timing = TTSSegmentTiming(byteRangeInConcatenatedAudio: lower ..< pcmCursor)
            } else {
                timing = .uncomputed
            }
            manifest.append(TTSManifestEntry(
                chunk: segment.chunk,
                encoding: segment.encoding,
                timing: timing
            ))
        }

        return TTSConcatenationResult(audio: audio, manifest: manifest)
    }

    private static func appendingConcatenation(_ audioSegments: [Data]) -> Data {
        var result = Data()
        result.reserveCapacity(audioSegments.reduce(0) { $0 + $1.count })
        for audioSegment in audioSegments {
            result.append(audioSegment)
        }
        return result
    }

    private static func makePublicChunks(_ internalChunks: [SentenceChunker.Chunk]) -> [TTSChunk] {
        let total = internalChunks.count
        return internalChunks.enumerated().map { index, chunk in
            TTSChunk(index: index, total: total, text: chunk.text, sourceRange: chunk.sourceRange)
        }
    }

    private static func executeChunks(
        _ chunks: [TTSChunk],
        voice: String,
        options: TTSOptions,
        encoding: TTSAudioEncoding,
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
                    let chunk = chunks[nextToSend]
                    let context = TTSChunkContext(chunk: chunk, encoding: encoding)
                    group.addTask {
                        do {
                            let data = try await provider.generate(
                                text: chunk.text,
                                voice: voice,
                                options: options,
                                context: context
                            )
                            return (chunk.index, data)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as TransportError {
                            throw TTSError.chunkFailed(
                                index: chunk.index,
                                total: totalChunks,
                                sourceRange: chunk.sourceRange,
                                error
                            )
                        } catch {
                            throw TTSError.chunkFailed(
                                index: chunk.index,
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
                    continuation.yield(TTSSegment(
                        chunk: chunks[nextToYield],
                        encoding: encoding,
                        timing: .uncomputed,
                        audio: audio
                    ))
                    nextToYield += 1
                }
            }
        }
    }
}
