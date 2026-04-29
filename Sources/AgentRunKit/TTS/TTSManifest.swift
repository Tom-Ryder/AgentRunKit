import Foundation

/// Concatenated audio plus a per-segment manifest produced by a manifest-aware ``TTSClient`` operation.
public struct TTSConcatenationResult: Sendable, Equatable {
    public let audio: Data
    public let manifest: [TTSManifestEntry]

    public init(audio: Data, manifest: [TTSManifestEntry]) {
        self.audio = audio
        self.manifest = manifest
    }
}

/// One segment's chunk, encoding, and timing within a ``TTSConcatenationResult`` manifest.
public struct TTSManifestEntry: Sendable, Equatable, Codable {
    public let chunk: TTSChunk
    public let encoding: TTSAudioEncoding
    public let timing: TTSSegmentTiming

    public init(chunk: TTSChunk, encoding: TTSAudioEncoding, timing: TTSSegmentTiming) {
        self.chunk = chunk
        self.encoding = encoding
        self.timing = timing
    }
}
