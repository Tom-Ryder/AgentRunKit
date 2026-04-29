import Foundation

/// Audio-time metadata for a TTS segment; fields are populated where the framework can compute them.
public struct TTSSegmentTiming: Sendable, Equatable, Codable {
    public let byteRangeInConcatenatedAudio: Range<Int>?
    public let durationSeconds: Double?

    public init(byteRangeInConcatenatedAudio: Range<Int>? = nil, durationSeconds: Double? = nil) {
        self.byteRangeInConcatenatedAudio = byteRangeInConcatenatedAudio
        self.durationSeconds = durationSeconds
    }

    public static let uncomputed = TTSSegmentTiming()
}
