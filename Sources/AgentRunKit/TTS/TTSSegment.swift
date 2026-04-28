import Foundation

/// A streamed chunk emitted by ``TTSClient/stream(text:voice:options:)``.
public struct TTSSegment: Sendable, Equatable {
    public let index: Int
    public let total: Int
    public let text: String
    /// UTF-8 byte offsets into the original input string passed to ``TTSClient/stream(text:voice:options:)``.
    public let sourceRange: Range<Int>
    public let audio: Data

    public init(index: Int, total: Int, text: String, sourceRange: Range<Int>, audio: Data) {
        self.index = index
        self.total = total
        self.text = text
        self.sourceRange = sourceRange
        self.audio = audio
    }
}
