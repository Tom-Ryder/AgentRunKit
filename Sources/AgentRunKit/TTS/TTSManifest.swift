import Foundation

/// Concatenated audio plus a per-segment manifest produced by a manifest-aware ``TTSClient`` operation.
public struct TTSConcatenationResult: Sendable, Equatable {
    public let audio: Data
    public let manifest: [TTSManifestEntry]
    /// The whole-program loudness outcome when loudness matching ran, or nil otherwise.
    public let loudness: TTSLoudnessSummary?

    public init(audio: Data, manifest: [TTSManifestEntry], loudness: TTSLoudnessSummary? = nil) {
        self.audio = audio
        self.manifest = manifest
        self.loudness = loudness
    }
}

/// One segment's chunk, encoding, and timing within a ``TTSConcatenationResult`` manifest.
public struct TTSManifestEntry: Sendable, Equatable, Codable {
    public let chunk: TTSChunk
    public let encoding: TTSAudioEncoding
    public let timing: TTSSegmentTiming
    /// The loudness measured for this segment and the gain applied, when loudness matching ran.
    public let loudness: TTSLoudnessMeasurement?

    public init(
        chunk: TTSChunk,
        encoding: TTSAudioEncoding,
        timing: TTSSegmentTiming,
        loudness: TTSLoudnessMeasurement? = nil
    ) {
        self.chunk = chunk
        self.encoding = encoding
        self.timing = timing
        self.loudness = loudness
    }
}
