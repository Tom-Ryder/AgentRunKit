import Foundation

/// A unit of input text that ``TTSClient`` synthesizes as one provider call.
public struct TTSChunk: Sendable, Equatable, Hashable, Codable {
    public let index: Int
    public let total: Int
    public let text: String
    /// UTF-8 byte offsets into the original input string passed to the ``TTSClient`` call.
    public let sourceRange: Range<Int>

    public init(index: Int, total: Int, text: String, sourceRange: Range<Int>) {
        self.index = index
        self.total = total
        self.text = text
        self.sourceRange = sourceRange
    }
}
