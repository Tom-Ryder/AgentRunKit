@testable import AgentRunKit
import Foundation
import Testing

struct SentenceChunkerTests {
    @Test
    func emptyStringReturnsEmptyArray() {
        #expect(SentenceChunker.chunk(text: "", maxCharacters: 100) == [])
    }

    @Test
    func whitespaceOnlyReturnsEmptyArray() {
        #expect(SentenceChunker.chunk(text: "   \n\n\t  ", maxCharacters: 100) == [])
    }

    @Test
    func shortTextReturnsSingleChunk() {
        let text = "Hello world."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 100)
        #expect(chunks == ["Hello world."])
    }

    @Test
    func multipleSentencesGroupedCorrectly() {
        let text = "First sentence. Second sentence. Third sentence."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 35)
        #expect(chunks == ["First sentence. Second sentence. ", "Third sentence."])
    }

    @Test
    func oversizedSentenceSplitAtWordBoundaries() {
        let text = "This is a very long sentence that exceeds the character limit."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 20)
        #expect(chunks == ["This is a very long", "sentence that", "exceeds the", "character limit."])
    }

    @Test
    func oversizedWordSplitAtCharacterBoundaries() {
        let text = "abcdefghijklmnopqrstuvwxyz"
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 10)
        #expect(chunks == ["abcdefghij", "klmnopqrst", "uvwxyz"])
    }

    @Test
    func abbreviationsNotSplitIncorrectly() {
        let text = "Dr. Smith went home. He was tired."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 100)
        #expect(chunks == [text])
    }

    @Test
    func numbersHandledCorrectly() {
        let text = "The price is $3.50. That is expensive."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 25)
        #expect(chunks == ["The price is $3.50. ", "That is expensive."])
    }

    @Test
    func paragraphBreaksRespected() {
        let text = "First paragraph.\n\nSecond paragraph."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 25)
        #expect(chunks == ["First paragraph.\n\n", "Second paragraph."])
    }

    @Test
    func unicodeTextHandled() {
        let text = "Great news! The price is \u{00A5}500. \u{1F600}\u{1F389}\u{1F680}"
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 100)
        let joined = chunks.joined()
        #expect(joined == text)

        let cjk = "\u{4ECA}\u{5929}\u{306F}\u{3044}\u{3044}\u{5929}\u{6C17}\u{3067}\u{3059}\u{3002}"
            + "\u{660E}\u{65E5}\u{3082}\u{6674}\u{308C}\u{307E}\u{3059}\u{3002}"
        let cjkChunks = SentenceChunker.chunk(text: cjk, maxCharacters: 100)
        let cjkJoined = cjkChunks.joined()
        #expect(cjkJoined == cjk)
    }

    @Test
    func exactBoundaryTextLengthEqualsMax() {
        let text = "Hello."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 6)
        #expect(chunks == ["Hello."])
    }

    @Test
    func allChunksWithinLimit() {
        let text = "One. Two. Three. Four. Five. Six. Seven. Eight. Nine. Ten."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 15)
        #expect(chunks == ["One. Two. ", "Three. Four. ", "Five. Six. ", "Seven. Eight. ", "Nine. Ten."])
    }

    @Test
    func singleCharacterText() {
        let chunks = SentenceChunker.chunk(text: ".", maxCharacters: 1)
        #expect(chunks == ["."])
    }
}
