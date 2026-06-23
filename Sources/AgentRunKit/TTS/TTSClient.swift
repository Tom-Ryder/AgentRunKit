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
        let format = options.responseFormat ?? provider.config.defaultFormat
        let encoding = provider.resolvedEncoding(for: format, options: options)
        let leadingShift = SentenceChunker.trimByteOffset(in: text)
        let chunk = TTSChunk(
            index: 0,
            total: 1,
            text: trimmed,
            sourceRange: leadingShift ..< (leadingShift + trimmed.utf8.count),
            trailingBoundary: .end
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
        let internalChunks = SentenceChunker.chunk(
            text: text,
            maxCharacters: provider.config.maxChunkCharacters
        )
        guard !internalChunks.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TTSError.emptyText) }
        }
        return segmentStream(
            plan: Self.makePublicChunks(internalChunks),
            voice: voice ?? provider.config.defaultVoice,
            options: options,
            encoding: provider.resolvedEncoding(
                for: options.responseFormat ?? provider.config.defaultFormat,
                options: options
            )
        )
    }

    public func generateAll(
        text: String,
        voice: String? = nil,
        options: TTSOptions = TTSOptions()
    ) async throws -> Data {
        try await generateWithManifest(text: text, voice: voice, options: options).audio
    }

    /// Synthesizes the input and returns concatenated audio plus a per-segment manifest; chunk failure throws.
    ///
    /// Pass a ``TTSStitchPolicy`` to assemble 16-bit PCM segments with boundary-keyed pauses and
    /// click-safe fades; without one, segments are concatenated raw.
    public func generateWithManifest(
        text: String,
        voice: String? = nil,
        options: TTSOptions = TTSOptions(),
        stitch: TTSStitchPolicy? = nil
    ) async throws -> TTSConcatenationResult {
        let encoding = provider.resolvedEncoding(
            for: options.responseFormat ?? provider.config.defaultFormat,
            options: options
        )
        if let stitch {
            _ = try resolvePCMFormat(for: encoding, loudness: stitch.loudness != nil)
        }
        let internalChunks = SentenceChunker.chunk(
            text: text,
            maxCharacters: provider.config.maxChunkCharacters,
            targetCharacters: stitch?.targetCharacters,
            preferParagraphBoundaries: stitch?.preferParagraphBoundaries ?? false
        )
        guard !internalChunks.isEmpty else {
            throw TTSError.emptyText
        }
        let (segments, _) = try await Self.runChunks(
            Self.makePublicChunks(internalChunks),
            voice: voice ?? provider.config.defaultVoice,
            options: options,
            encoding: encoding,
            provider: provider,
            maxConcurrent: maxConcurrent,
            handling: .failFast
        )
        if let stitch {
            return try self.stitch(segments: segments, policy: stitch)
        }
        return try concatenate(segments: segments)
    }

    /// Synthesizes chunk by chunk, returning each chunk's outcome and preserving completed audio past a failure.
    public func generateBatch(
        text: String,
        voice: String? = nil,
        options: TTSOptions = TTSOptions(),
        stitch: TTSStitchPolicy? = nil
    ) async throws -> TTSBatchResult {
        let encoding = provider.resolvedEncoding(
            for: options.responseFormat ?? provider.config.defaultFormat,
            options: options
        )
        if let stitch {
            _ = try resolvePCMFormat(for: encoding, loudness: stitch.loudness != nil)
        }
        let internalChunks = SentenceChunker.chunk(
            text: text,
            maxCharacters: provider.config.maxChunkCharacters,
            targetCharacters: stitch?.targetCharacters,
            preferParagraphBoundaries: stitch?.preferParagraphBoundaries ?? false
        )
        guard !internalChunks.isEmpty else {
            throw TTSError.emptyText
        }
        let plan = Self.makePublicChunks(internalChunks)
        let (segments, failures) = try await Self.runChunks(
            plan,
            voice: voice ?? provider.config.defaultVoice,
            options: options,
            encoding: encoding,
            provider: provider,
            maxConcurrent: maxConcurrent,
            handling: .collect
        )
        return TTSBatchResult(total: plan.count, completedSegments: segments, failures: failures)
    }

    /// Re-synthesizes exactly the given chunks, returning a sparse ``TTSBatchResult`` to merge into a prior batch.
    public func generate(
        chunks: [TTSChunk],
        voice: String? = nil,
        options: TTSOptions = TTSOptions()
    ) async throws -> TTSBatchResult {
        guard let total = chunks.first?.total else {
            throw TTSError.invalidConfiguration("generate(chunks:) requires at least one chunk")
        }
        let indices = chunks.map(\.index)
        guard chunks.allSatisfy({ $0.total == total }),
              indices.allSatisfy({ (0 ..< total).contains($0) }),
              Set(indices).count == indices.count
        else {
            throw TTSError.invalidConfiguration("chunks must share one total and hold unique indices within 0..<total")
        }
        let encoding = provider.resolvedEncoding(
            for: options.responseFormat ?? provider.config.defaultFormat,
            options: options
        )
        let (segments, failures) = try await Self.runChunks(
            chunks,
            voice: voice ?? provider.config.defaultVoice,
            options: options,
            encoding: encoding,
            provider: provider,
            maxConcurrent: maxConcurrent,
            handling: .collect
        )
        return TTSBatchResult(total: total, completedSegments: segments, failures: failures)
    }

    /// Concatenates a complete, gap-free segment set into one audio buffer plus a manifest, with no stitching.
    public func concatenate(segments: [TTSSegment]) throws -> TTSConcatenationResult {
        let (ordered, encoding) = try validatedAssembly(segments)
        let (audio, byteRanges) = Self.concatenate(ordered.map(\.audio), format: encoding.format)
        var manifest: [TTSManifestEntry] = []
        manifest.reserveCapacity(ordered.count)
        for (segment, range) in zip(ordered, byteRanges) {
            manifest.append(TTSManifestEntry(
                chunk: segment.chunk,
                encoding: segment.encoding,
                timing: TTSSegmentTiming(
                    byteRangeInConcatenatedAudio: range,
                    durationSeconds: Self.durationSeconds(forSegment: segment)
                )
            ))
        }
        return TTSConcatenationResult(audio: audio, manifest: manifest)
    }

    /// Stitches a complete, gap-free 16-bit PCM segment set with boundary-keyed pauses, fades, and optional loudness.
    public func stitch(segments: [TTSSegment], policy: TTSStitchPolicy) throws -> TTSConcatenationResult {
        let (ordered, encoding) = try validatedAssembly(segments)
        let format = try resolvePCMFormat(for: encoding, loudness: policy.loudness != nil)
        guard ordered.allSatisfy({ $0.audio.count.isMultiple(of: format.bytesPerFrame) }) else {
            throw TTSError.invalidConfiguration("stitching requires PCM segments aligned to whole 16-bit frames")
        }
        return try Self.stitched(segments: ordered, format: format, policy: policy)
    }
}

private extension TTSClient {
    func segmentStream(
        plan publicChunks: [TTSChunk],
        voice resolvedVoice: String,
        options: TTSOptions,
        encoding: TTSAudioEncoding
    ) -> AsyncThrowingStream<TTSSegment, Error> {
        let provider = provider
        let maxConcurrent = maxConcurrent
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await Self.runChunks(
                        publicChunks,
                        voice: resolvedVoice,
                        options: options,
                        encoding: encoding,
                        provider: provider,
                        maxConcurrent: maxConcurrent,
                        handling: .failFast,
                        onSegment: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func stitched(
        segments: [TTSSegment],
        format: PCMFormat,
        policy: TTSStitchPolicy
    ) throws -> TTSConcatenationResult {
        if let loudness = policy.loudness {
            let output = try TTSLoudnessMatcher.match(
                segments: segments.map(\.audio),
                boundaries: segments.map(\.chunk.trailingBoundary),
                policy: policy,
                loudness: loudness,
                format: format
            )
            let entries = makeManifest(
                segments: segments,
                ranges: output.ranges,
                measurements: output.measurements,
                format: format
            )
            return TTSConcatenationResult(audio: output.audio, manifest: entries, loudness: output.summary)
        }

        let result = PCMStitcher.stitch(
            segments: segments.map(\.audio),
            boundaries: segments.map(\.chunk.trailingBoundary),
            policy: policy,
            format: format
        )
        let entries = makeManifest(segments: segments, ranges: result.ranges, measurements: nil, format: format)
        return TTSConcatenationResult(audio: result.audio, manifest: entries)
    }

    static func makeManifest(
        segments: [TTSSegment],
        ranges: [Range<Int>],
        measurements: [TTSLoudnessMeasurement]?,
        format: PCMFormat
    ) -> [TTSManifestEntry] {
        let bytesPerSecond = Double(format.bytesPerSecond)
        var entries: [TTSManifestEntry] = []
        entries.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            let range = ranges[index]
            entries.append(TTSManifestEntry(
                chunk: segment.chunk,
                encoding: segment.encoding,
                timing: TTSSegmentTiming(
                    byteRangeInConcatenatedAudio: range,
                    durationSeconds: Double(range.count) / bytesPerSecond
                ),
                loudness: measurements?[index]
            ))
        }
        return entries
    }

    static func durationSeconds(forSegment segment: TTSSegment) -> Double? {
        guard segment.encoding.format == .pcm,
              let sampleRate = segment.encoding.sampleRate,
              let channels = segment.encoding.channels,
              let bitsPerSample = segment.encoding.bitsPerSample,
              sampleRate > 0, channels > 0,
              bitsPerSample > 0, bitsPerSample.isMultiple(of: 8)
        else { return nil }
        let bytesPerSample = bitsPerSample / 8
        let (channelBytes, channelOverflow) = sampleRate.multipliedReportingOverflow(by: channels)
        guard !channelOverflow else { return nil }
        let (bytesPerSecond, totalOverflow) = channelBytes.multipliedReportingOverflow(by: bytesPerSample)
        guard !totalOverflow, bytesPerSecond > 0 else { return nil }
        return Double(segment.audio.count) / Double(bytesPerSecond)
    }

    static func concatenate(
        _ audioSegments: [Data],
        format: TTSAudioFormat
    ) -> (audio: Data, byteRanges: [Range<Int>?]) {
        switch format {
        case .mp3:
            let result = MP3Concatenator.concatenateWithRanges(audioSegments)
            return (result.audio, result.ranges as [Range<Int>?])
        case .pcm:
            let audio = appendingConcatenation(audioSegments)
            var ranges: [Range<Int>?] = []
            ranges.reserveCapacity(audioSegments.count)
            var cursor = 0
            for segment in audioSegments {
                let lower = cursor
                cursor += segment.count
                ranges.append(lower ..< cursor)
            }
            return (audio, ranges)
        case .opus, .aac, .flac, .wav:
            let audio = appendingConcatenation(audioSegments)
            return (audio, Array(repeating: nil, count: audioSegments.count))
        }
    }

    static func appendingConcatenation(_ audioSegments: [Data]) -> Data {
        var result = Data()
        result.reserveCapacity(audioSegments.reduce(0) { $0 + $1.count })
        for audioSegment in audioSegments {
            result.append(audioSegment)
        }
        return result
    }

    static func makePublicChunks(_ internalChunks: [SentenceChunker.Chunk]) -> [TTSChunk] {
        let total = internalChunks.count
        return internalChunks.enumerated().map { index, chunk in
            TTSChunk(
                index: index,
                total: total,
                text: chunk.text,
                sourceRange: chunk.sourceRange,
                trailingBoundary: chunk.trailingBoundary
            )
        }
    }

    enum ChunkFailureHandling {
        case failFast
        case collect
    }

    private enum ChunkAttempt {
        case success(TTSSegment)
        case failure(TTSChunkFailure)
    }

    static func runChunks(
        _ chunks: [TTSChunk],
        voice: String,
        options: TTSOptions,
        encoding: TTSAudioEncoding,
        provider: P,
        maxConcurrent: Int,
        handling: ChunkFailureHandling,
        onSegment: ((TTSSegment) -> Void)? = nil
    ) async throws -> (segments: [TTSSegment], failures: [TTSChunkFailure]) {
        try await withThrowingTaskGroup(of: ChunkAttempt.self) { group in
            var nextToSend = 0
            var activeTasks = 0
            var buffer: [Int: TTSSegment] = [:]
            var emitCursor = 0
            var segments: [TTSSegment] = []
            var failures: [TTSChunkFailure] = []

            while nextToSend < chunks.count || activeTasks > 0 {
                try Task.checkCancellation()
                while activeTasks < maxConcurrent, nextToSend < chunks.count {
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
                            return .success(TTSSegment(
                                chunk: chunk,
                                encoding: encoding,
                                timing: .uncomputed,
                                audio: data
                            ))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as TransportError {
                            return .failure(TTSChunkFailure(chunk: chunk, encoding: encoding, error: error))
                        } catch {
                            return .failure(TTSChunkFailure(
                                chunk: chunk,
                                encoding: encoding,
                                error: .other(String(describing: error))
                            ))
                        }
                    }
                    nextToSend += 1
                    activeTasks += 1
                }

                guard let attempt = try await group.next() else { break }
                activeTasks -= 1

                switch attempt {
                case let .success(segment):
                    if let onSegment {
                        buffer[segment.index] = segment
                        while let next = buffer.removeValue(forKey: emitCursor) {
                            onSegment(next)
                            emitCursor += 1
                        }
                    } else {
                        segments.append(segment)
                    }
                case let .failure(failure):
                    if handling == .failFast {
                        throw TTSError.chunkFailed(
                            index: failure.index,
                            total: failure.total,
                            sourceRange: failure.sourceRange,
                            failure.error
                        )
                    }
                    failures.append(failure)
                }
            }

            return (segments, failures)
        }
    }

    private func resolvePCMFormat(for encoding: TTSAudioEncoding, loudness: Bool) throws -> PCMFormat {
        guard let format = PCMFormat(encoding) else {
            throw TTSError.invalidConfiguration(
                "stitching requires 16-bit PCM output with a known sample rate and channel count"
            )
        }
        if loudness, format.channels != 1 {
            throw TTSError.invalidConfiguration("loudness matching requires mono (1-channel) 16-bit PCM")
        }
        return format
    }

    private func validatedAssembly(
        _ segments: [TTSSegment]
    ) throws -> (segments: [TTSSegment], encoding: TTSAudioEncoding) {
        guard let first = segments.first else {
            throw TTSError.invalidConfiguration("cannot assemble an empty segment set")
        }
        let total = first.total
        let ordered = segments.sorted { $0.index < $1.index }
        guard ordered.count == total, ordered.map(\.index) == Array(0 ..< total) else {
            throw TTSError.invalidConfiguration(
                "assembly requires a complete, gap-free run of segments covering 0..<\(total)"
            )
        }
        guard ordered.allSatisfy({ $0.encoding == first.encoding && $0.total == total }) else {
            throw TTSError.invalidConfiguration("assembly requires every segment to share one encoding and total")
        }
        return (ordered, first.encoding)
    }
}
