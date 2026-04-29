import Foundation

/// A streamed chunk emitted by ``TTSClient/stream(text:voice:options:)``.
public struct TTSSegment: Sendable, Equatable {
    public let chunk: TTSChunk
    public let encoding: TTSAudioEncoding
    public let timing: TTSSegmentTiming
    public let audio: Data

    public init(chunk: TTSChunk, encoding: TTSAudioEncoding, timing: TTSSegmentTiming, audio: Data) {
        self.chunk = chunk
        self.encoding = encoding
        self.timing = timing
        self.audio = audio
    }

    public var index: Int {
        chunk.index
    }

    public var total: Int {
        chunk.total
    }

    public var text: String {
        chunk.text
    }

    public var sourceRange: Range<Int> {
        chunk.sourceRange
    }
}
