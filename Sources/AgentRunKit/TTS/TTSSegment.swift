import Foundation

/// A single audio segment from a chunked TTS generation.
public struct TTSSegment: Sendable, Equatable {
    public let index: Int
    public let total: Int
    public let audio: Data

    public init(index: Int, total: Int, audio: Data) {
        self.index = index
        self.total = total
        self.audio = audio
    }
}
