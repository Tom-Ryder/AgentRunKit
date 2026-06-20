@testable import AgentRunKit
import Foundation
import Testing

private typealias Chunk = SentenceChunker.Chunk

struct SentenceChunkerTests {
    @Test
    func emptyStringReturnsEmptyArray() {
        #expect(SentenceChunker.chunk(text: "", maxCharacters: 100).isEmpty)
    }

    @Test
    func whitespaceOnlyReturnsEmptyArray() {
        #expect(SentenceChunker.chunk(text: "   \n\n\t  ", maxCharacters: 100).isEmpty)
    }

    @Test
    func shortTextReturnsSingleChunk() {
        let chunks = SentenceChunker.chunk(text: "Hello world.", maxCharacters: 100)
        #expect(chunks == [Chunk(text: "Hello world.", sourceRange: 0 ..< 12, trailingBoundary: .end)])
    }

    @Test
    func multipleSentencesGroupedCorrectly() {
        let text = "First sentence. Second sentence. Third sentence."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 35)
        #expect(chunks == [
            Chunk(text: "First sentence. Second sentence. ", sourceRange: 0 ..< 33, trailingBoundary: .sentence),
            Chunk(text: "Third sentence.", sourceRange: 33 ..< 48, trailingBoundary: .end),
        ])
    }

    @Test
    func oversizedSentenceSplitAtWordBoundaries() {
        let text = "This is a very long sentence that exceeds the character limit."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 20)
        #expect(chunks == [
            Chunk(text: "This is a very long", sourceRange: 0 ..< 19, trailingBoundary: .withinSentence),
            Chunk(text: "sentence that", sourceRange: 20 ..< 33, trailingBoundary: .withinSentence),
            Chunk(text: "exceeds the", sourceRange: 34 ..< 45, trailingBoundary: .withinSentence),
            Chunk(text: "character limit.", sourceRange: 46 ..< 62, trailingBoundary: .end),
        ])
    }

    @Test
    func oversizedWordSplitAtCharacterBoundaries() {
        let chunks = SentenceChunker.chunk(text: "abcdefghijklmnopqrstuvwxyz", maxCharacters: 10)
        #expect(chunks == [
            Chunk(text: "abcdefghij", sourceRange: 0 ..< 10, trailingBoundary: .withinSentence),
            Chunk(text: "klmnopqrst", sourceRange: 10 ..< 20, trailingBoundary: .withinSentence),
            Chunk(text: "uvwxyz", sourceRange: 20 ..< 26, trailingBoundary: .end),
        ])
    }

    @Test
    func abbreviationsNotSplitIncorrectly() {
        let text = "Dr. Smith went home. He was tired."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 100)
        #expect(chunks == [Chunk(text: text, sourceRange: 0 ..< 34, trailingBoundary: .end)])
    }

    @Test
    func numbersHandledCorrectly() {
        let text = "The price is $3.50. That is expensive."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 25)
        #expect(chunks == [
            Chunk(text: "The price is $3.50. ", sourceRange: 0 ..< 20, trailingBoundary: .sentence),
            Chunk(text: "That is expensive.", sourceRange: 20 ..< 38, trailingBoundary: .end),
        ])
    }

    @Test
    func paragraphBreaksRespected() {
        let text = "First paragraph.\n\nSecond paragraph."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 25)
        #expect(chunks == [
            Chunk(text: "First paragraph.\n\n", sourceRange: 0 ..< 18, trailingBoundary: .paragraph),
            Chunk(text: "Second paragraph.", sourceRange: 18 ..< 35, trailingBoundary: .end),
        ])
    }

    @Test
    func unicodeTextRoundTrips() {
        let text = "Great news! The price is \u{00A5}500. \u{1F600}\u{1F389}\u{1F680}"
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 100)
        #expect(chunks.map(\.text).joined() == text)
        #expect(chunks.last?.sourceRange.upperBound == text.utf8.count)

        let cjk = "\u{4ECA}\u{5929}\u{306F}\u{3044}\u{3044}\u{5929}\u{6C17}\u{3067}\u{3059}\u{3002}"
            + "\u{660E}\u{65E5}\u{3082}\u{6674}\u{308C}\u{307E}\u{3059}\u{3002}"
        let cjkChunks = SentenceChunker.chunk(text: cjk, maxCharacters: 100)
        #expect(cjkChunks.map(\.text).joined() == cjk)
        #expect(cjkChunks.last?.sourceRange.upperBound == cjk.utf8.count)
    }

    @Test
    func exactBoundaryTextLengthEqualsMax() {
        let chunks = SentenceChunker.chunk(text: "Hello.", maxCharacters: 6)
        #expect(chunks == [Chunk(text: "Hello.", sourceRange: 0 ..< 6, trailingBoundary: .end)])
    }

    @Test
    func allChunksWithinLimit() {
        let text = "One. Two. Three. Four. Five. Six. Seven. Eight. Nine. Ten."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 15)
        #expect(chunks == [
            Chunk(text: "One. Two. ", sourceRange: 0 ..< 10, trailingBoundary: .sentence),
            Chunk(text: "Three. Four. ", sourceRange: 10 ..< 23, trailingBoundary: .sentence),
            Chunk(text: "Five. Six. ", sourceRange: 23 ..< 34, trailingBoundary: .sentence),
            Chunk(text: "Seven. Eight. ", sourceRange: 34 ..< 48, trailingBoundary: .sentence),
            Chunk(text: "Nine. Ten.", sourceRange: 48 ..< 58, trailingBoundary: .end),
        ])
    }

    @Test
    func singleCharacterText() {
        let chunks = SentenceChunker.chunk(text: ".", maxCharacters: 1)
        #expect(chunks == [Chunk(text: ".", sourceRange: 0 ..< 1, trailingBoundary: .end)])
    }

    @Test
    func sentenceTierRangesRoundTripToOriginal() throws {
        let text = "First sentence. Second sentence. Third sentence."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 35)
        let utf8 = Array(text.utf8)
        for chunk in chunks {
            let slice = Data(utf8[chunk.sourceRange])
            let decoded = try #require(String(bytes: slice, encoding: .utf8))
            #expect(decoded == chunk.text)
        }
    }

    @Test
    func oversizedSentenceTierRangesAreDiscontiguousSpans() {
        let text = "This is a very long sentence that exceeds the character limit."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 20)
        for index in 1 ..< chunks.count {
            #expect(chunks[index].sourceRange.lowerBound > chunks[index - 1].sourceRange.upperBound)
        }
    }

    @Test
    func leadingWhitespaceShiftsRanges() throws {
        let text = "   Hello world."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 100)
        #expect(chunks == [Chunk(text: "Hello world.", sourceRange: 3 ..< 15, trailingBoundary: .end)])
        let slice = Data(Array(text.utf8)[chunks[0].sourceRange])
        let decoded = try #require(String(bytes: slice, encoding: .utf8))
        #expect(decoded == chunks[0].text)
    }

    @Test
    func trailingWhitespaceDoesNotInflateRange() {
        let chunks = SentenceChunker.chunk(text: "Hello.   ", maxCharacters: 100)
        #expect(chunks == [Chunk(text: "Hello.", sourceRange: 0 ..< 6, trailingBoundary: .end)])
    }

    @Test
    func leadingWhitespaceShiftsCharacterTierRanges() {
        let text = "   " + String(repeating: "a", count: 30)
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 10)
        #expect(chunks == [
            Chunk(text: String(repeating: "a", count: 10), sourceRange: 3 ..< 13, trailingBoundary: .withinSentence),
            Chunk(text: String(repeating: "a", count: 10), sourceRange: 13 ..< 23, trailingBoundary: .withinSentence),
            Chunk(text: String(repeating: "a", count: 10), sourceRange: 23 ..< 33, trailingBoundary: .end),
        ])
    }

    @Test
    func leadingWhitespaceShiftsWordSplitRanges() {
        let text = "   This is a very long sentence that exceeds the character limit."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 20)
        #expect(chunks == [
            Chunk(text: "This is a very long", sourceRange: 3 ..< 22, trailingBoundary: .withinSentence),
            Chunk(text: "sentence that", sourceRange: 23 ..< 36, trailingBoundary: .withinSentence),
            Chunk(text: "exceeds the", sourceRange: 37 ..< 48, trailingBoundary: .withinSentence),
            Chunk(text: "character limit.", sourceRange: 49 ..< 65, trailingBoundary: .end),
        ])
    }

    @Test
    func unicodeMultiByteRangesAreUTF8() throws {
        let text = "\u{4ECA}\u{65E5}\u{306F}."
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 100)
        let totalBytes = chunks.reduce(0) { $0 + $1.sourceRange.count }
        #expect(totalBytes == 10)
        let utf8 = Array(text.utf8)
        for chunk in chunks {
            let slice = Data(utf8[chunk.sourceRange])
            let decoded = try #require(String(bytes: slice, encoding: .utf8))
            #expect(decoded == chunk.text)
        }
    }

    @Test
    func cjkSplitAtCharacterBoundariesPreservesUTF8Bytes() throws {
        let text = String(repeating: "\u{4ECA}", count: 6)
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 3)
        let totalBytes = chunks.reduce(0) { $0 + $1.sourceRange.count }
        #expect(totalBytes == 18)
        #expect(chunks.last?.sourceRange.upperBound == 18)
        for chunk in chunks {
            #expect(chunk.sourceRange.count.isMultiple(of: 3))
        }
        let utf8 = Array(text.utf8)
        for chunk in chunks {
            let slice = Data(utf8[chunk.sourceRange])
            let decoded = try #require(String(bytes: slice, encoding: .utf8))
            #expect(decoded == chunk.text)
        }
    }
}

struct SentenceChunkerBoundaryTests {
    @Test
    func singleNewlineClassifiesAsSentenceNotParagraph() {
        let chunks = SentenceChunker.chunk(text: "Line one.\nLine two.", maxCharacters: 10)
        #expect(chunks.count == 2)
        #expect(chunks.first?.trailingBoundary == .sentence)
        #expect(chunks.last?.trailingBoundary == .end)
    }

    @Test
    func oversizedSentenceLastPieceClassifiedByWhatFollows() {
        let chunks = SentenceChunker.chunk(text: "alpha bravo charlie delta. Echo foxtrot.", maxCharacters: 15)
        #expect(chunks.count == 3)
        #expect(chunks[0].trailingBoundary == .withinSentence)
        #expect(chunks[1].trailingBoundary == .sentence)
        #expect(chunks[2].trailingBoundary == .end)
    }

    @Test
    func greedyChunksReassembleToTrimmedInput() {
        let text = "  First sentence. Second sentence.\n\nThird one.  "
        let chunks = SentenceChunker.chunk(text: text, maxCharacters: 18)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(chunks.map(\.text).joined() == trimmed)
    }

    @Test
    func oversizedSentenceBeforeParagraphEmitsNoWhitespaceChunk() {
        let chunks = SentenceChunker.chunk(
            text: "alpha bravo charlie delta echo foxtrot golf.\n\nNext para here.",
            maxCharacters: 15
        )
        #expect(!chunks.contains { $0.text.allSatisfy(\.isWhitespace) })
        #expect(chunks.count(where: { $0.trailingBoundary == .paragraph }) == 1)
        #expect(chunks.last?.trailingBoundary == .end)
    }

    @Test
    func paragraphSeparatorClassifiesAsParagraph() {
        let chunks = SentenceChunker.chunk(text: "First idea.\u{2029}Second idea.", maxCharacters: 12)
        #expect(chunks.contains { $0.trailingBoundary == .paragraph })
    }
}

struct SentenceChunkerSoftTargetTests {
    @Test
    func targetProducesSmallerChunksThanGreedyAndPreservesText() {
        let text = "One here. Two here. Three here. Four here. Five here. Six here."
        let greedy = SentenceChunker.chunk(text: text, maxCharacters: 200)
        let soft = SentenceChunker.chunk(text: text, maxCharacters: 200, targetCharacters: 20)
        #expect(greedy.count == 1)
        #expect(soft.count > greedy.count)
        #expect(soft.allSatisfy { $0.text.count <= 200 })
        #expect(soft.dropLast().allSatisfy { $0.trailingBoundary == .sentence })
        #expect(soft.last?.trailingBoundary == .end)
        #expect(soft.map(\.text).joined() == greedy.map(\.text).joined())
    }

    @Test
    func preferParagraphBoundariesKeepsParagraphsWhole() {
        let text = "Aaa one. Bbb two. Ccc three.\n\nDdd four. Eee five. Fff six."
        let withPrefer = SentenceChunker.chunk(
            text: text,
            maxCharacters: 200,
            targetCharacters: 20,
            preferParagraphBoundaries: true
        )
        let withoutPrefer = SentenceChunker.chunk(
            text: text,
            maxCharacters: 200,
            targetCharacters: 20,
            preferParagraphBoundaries: false
        )
        #expect(withPrefer.count == 2)
        #expect(withoutPrefer.count == 3)
        #expect(withPrefer.first?.trailingBoundary == .paragraph)
        #expect(withPrefer.map(\.text).joined() == text)
    }

    @Test
    func softTargetEmitsNoWhitespaceOnlyChunkAcrossParagraphBreak() {
        let text = "The first idea is simple.\n\nThe second idea is harder."
        let soft = SentenceChunker.chunk(text: text, maxCharacters: 26, targetCharacters: 20)
        #expect(!soft.contains { $0.text.allSatisfy(\.isWhitespace) })
        #expect(soft.first?.trailingBoundary == .paragraph)
        #expect(soft.map(\.text).joined() == text)
    }

    @Test
    func softTargetCutsAtExactSentenceBoundaries() {
        let chunks = SentenceChunker.chunk(
            text: "One here. Two here. Three here. Four here. Five here. Six here.",
            maxCharacters: 200,
            targetCharacters: 20
        )
        #expect(chunks == [
            Chunk(text: "One here. Two here. ", sourceRange: 0 ..< 20, trailingBoundary: .sentence),
            Chunk(text: "Three here. Four here. ", sourceRange: 20 ..< 43, trailingBoundary: .sentence),
            Chunk(text: "Five here. Six here.", sourceRange: 43 ..< 63, trailingBoundary: .end),
        ])
    }
}
