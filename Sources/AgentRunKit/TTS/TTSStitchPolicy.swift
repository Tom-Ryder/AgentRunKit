import Foundation

/// An opt-in policy for assembling PCM chunks into one stream with boundary-keyed pauses and click-safe fades.
public struct TTSStitchPolicy: Sendable, Equatable, Hashable, Codable {
    /// Soft character target the chunker fills toward before cutting at a sentence boundary,
    /// or nil to pack greedily to the provider maximum.
    public let targetCharacters: Int?
    /// Whether to extend past the target to cut on a paragraph boundary when one is in reach.
    public let preferParagraphBoundaries: Bool
    /// Silence inserted where a chunk ends a sentence.
    public let sentencePause: Duration
    /// Silence inserted where a chunk ends a paragraph.
    public let paragraphPause: Duration
    /// Edge fade applied into and out of each inserted pause to suppress clicks.
    public let joinFade: Duration

    public init(
        targetCharacters: Int? = nil,
        preferParagraphBoundaries: Bool = false,
        sentencePause: Duration = .zero,
        paragraphPause: Duration = .zero,
        joinFade: Duration = .zero
    ) {
        if let targetCharacters {
            precondition(targetCharacters >= 1, "targetCharacters must be at least 1")
        }
        precondition(sentencePause >= .zero, "sentencePause must not be negative")
        precondition(paragraphPause >= .zero, "paragraphPause must not be negative")
        precondition(joinFade >= .zero, "joinFade must not be negative")
        self.targetCharacters = targetCharacters
        self.preferParagraphBoundaries = preferParagraphBoundaries
        self.sentencePause = sentencePause
        self.paragraphPause = paragraphPause
        self.joinFade = joinFade
    }
}
