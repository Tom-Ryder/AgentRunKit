import Foundation

/// The textual boundary in the original input immediately following a ``TTSChunk``.
public enum TTSBoundary: String, Sendable, Codable, Equatable, Hashable {
    case sentence, paragraph, withinSentence, end
}
