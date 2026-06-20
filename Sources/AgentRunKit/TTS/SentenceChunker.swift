import Foundation
import NaturalLanguage

enum SentenceChunker {
    struct Chunk: Equatable {
        let text: String
        let sourceRange: Range<Int>
        let trailingBoundary: TTSBoundary
    }

    static func chunk(
        text: String,
        maxCharacters: Int,
        targetCharacters: Int? = nil,
        preferParagraphBoundaries: Bool = false
    ) -> [Chunk] {
        precondition(maxCharacters >= 1, "maxCharacters must be at least 1")
        if let targetCharacters {
            precondition(targetCharacters >= 1, "targetCharacters must be at least 1")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let trimShift = trimByteOffset(in: text)
        let pieces = rawPieces(
            in: trimmed,
            maxCharacters: maxCharacters,
            targetCharacters: targetCharacters,
            preferParagraphBoundaries: preferParagraphBoundaries
        )

        return pieces.enumerated().map { index, piece in
            let boundary: TTSBoundary =
                if index == pieces.count - 1 {
                    .end
                } else if piece.withinSentence {
                    .withinSentence
                } else {
                    classifySeam(in: trimmed, at: piece.upper)
                }
            return Chunk(
                text: piece.text,
                sourceRange: sourceRange(lower: piece.lower, upper: piece.upper, in: trimmed, shiftedBy: trimShift),
                trailingBoundary: boundary
            )
        }
    }

    private static func rawPieces(
        in trimmed: String,
        maxCharacters: Int,
        targetCharacters: Int?,
        preferParagraphBoundaries: Bool
    ) -> [RawPiece] {
        var pieces: [RawPiece] = []
        var accumulator = ChunkAccumulator()

        for range in enumerateSentences(trimmed) {
            let sentence = trimmed[range]

            if sentence.count > maxCharacters {
                if let piece = accumulator.flush() { pieces.append(piece) }
                let split = splitOversized(sentence, maxCharacters: maxCharacters)
                for (offset, piece) in split.enumerated() {
                    pieces.append(RawPiece(
                        text: piece.text,
                        lower: piece.lower,
                        upper: piece.upper,
                        withinSentence: offset < split.count - 1
                    ))
                }
                continue
            }

            if sentence.allSatisfy(\.isWhitespace) {
                absorbWhitespace(sentence, range: range, into: &accumulator, pieces: &pieces)
                continue
            }

            if accumulator.isEmpty {
                accumulator.reset(to: String(sentence), lower: range.lowerBound, upper: range.upperBound)
            } else if accumulator.count + sentence.count > maxCharacters {
                if let piece = accumulator.flush() { pieces.append(piece) }
                accumulator.reset(to: String(sentence), lower: range.lowerBound, upper: range.upperBound)
            } else if let targetCharacters, accumulator.count >= targetCharacters,
                      shouldCut(accumulator, in: trimmed, preferParagraphBoundaries: preferParagraphBoundaries) {
                if let piece = accumulator.flush() { pieces.append(piece) }
                accumulator.reset(to: String(sentence), lower: range.lowerBound, upper: range.upperBound)
            } else {
                accumulator.extend(with: String(sentence), upper: range.upperBound)
            }
        }

        if let piece = accumulator.flush() { pieces.append(piece) }
        return pieces
    }

    private static func absorbWhitespace(
        _ sentence: Substring,
        range: Range<String.Index>,
        into accumulator: inout ChunkAccumulator,
        pieces: inout [RawPiece]
    ) {
        if !accumulator.isEmpty {
            accumulator.extend(with: String(sentence), upper: range.upperBound)
        } else if !pieces.isEmpty {
            pieces[pieces.count - 1].text += String(sentence)
            pieces[pieces.count - 1].upper = range.upperBound
        } else {
            preconditionFailure("the trimmed input cannot begin with a whitespace-only token")
        }
    }

    private static func shouldCut(
        _ accumulator: ChunkAccumulator,
        in trimmed: String,
        preferParagraphBoundaries: Bool
    ) -> Bool {
        guard preferParagraphBoundaries, let upper = accumulator.upperIndex else { return true }
        return classifySeam(in: trimmed, at: upper) == .paragraph
    }

    private static let paragraphSeparator: Character = "\u{2029}"

    private static func classifySeam(in trimmed: String, at seam: String.Index) -> TTSBoundary {
        var newlines = 0
        var idx = seam
        while idx > trimmed.startIndex {
            let prev = trimmed.index(before: idx)
            let character = trimmed[prev]
            if character == paragraphSeparator {
                return .paragraph
            }
            if character.isNewline {
                newlines += 1
                if newlines >= 2 { return .paragraph }
            } else if !character.isWhitespace {
                break
            }
            idx = prev
        }
        idx = seam
        while idx < trimmed.endIndex {
            let character = trimmed[idx]
            if character == paragraphSeparator {
                return .paragraph
            }
            if character.isNewline {
                newlines += 1
                if newlines >= 2 { return .paragraph }
            } else if !character.isWhitespace {
                break
            }
            idx = trimmed.index(after: idx)
        }
        return newlines >= 2 ? .paragraph : .sentence
    }

    private static func enumerateSentences(_ text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        return ranges
    }

    private static func splitOversized(_ sentence: Substring, maxCharacters: Int) -> [RawPiece] {
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true)
        var pieces: [RawPiece] = []
        var accumulator = ChunkAccumulator()

        for word in words {
            if word.count > maxCharacters {
                if let piece = accumulator.flush() { pieces.append(piece) }
                pieces.append(contentsOf: splitAtCharacterBoundaries(word, maxCharacters: maxCharacters))
                continue
            }

            let separator = accumulator.isEmpty ? "" : " "
            if accumulator.count + separator.count + word.count <= maxCharacters {
                if accumulator.isEmpty {
                    accumulator.reset(to: String(word), lower: word.startIndex, upper: word.endIndex)
                } else {
                    accumulator.extend(with: separator + word, upper: word.endIndex)
                }
            } else {
                if let piece = accumulator.flush() { pieces.append(piece) }
                accumulator.reset(to: String(word), lower: word.startIndex, upper: word.endIndex)
            }
        }

        if let piece = accumulator.flush() { pieces.append(piece) }
        return pieces
    }

    private static func splitAtCharacterBoundaries(_ word: Substring, maxCharacters: Int) -> [RawPiece] {
        var pieces: [RawPiece] = []
        var startIndex = word.startIndex
        while startIndex < word.endIndex {
            let endIndex = word.index(startIndex, offsetBy: maxCharacters, limitedBy: word.endIndex) ?? word.endIndex
            pieces.append(RawPiece(
                text: String(word[startIndex ..< endIndex]),
                lower: startIndex,
                upper: endIndex,
                withinSentence: false
            ))
            startIndex = endIndex
        }
        return pieces
    }

    private static func sourceRange(
        lower: String.Index,
        upper: String.Index,
        in trimmed: String,
        shiftedBy trimShift: Int
    ) -> Range<Int> {
        let lowerOffset = trimmed.utf8.distance(from: trimmed.startIndex, to: lower)
        let upperOffset = trimmed.utf8.distance(from: trimmed.startIndex, to: upper)
        return (lowerOffset + trimShift) ..< (upperOffset + trimShift)
    }

    static func trimByteOffset(in original: String) -> Int {
        guard let firstNonWS = original.unicodeScalars.firstIndex(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return 0 }
        return original.utf8.distance(from: original.startIndex, to: firstNonWS)
    }
}

private struct RawPiece {
    var text: String
    var lower: String.Index
    var upper: String.Index
    var withinSentence: Bool
}

private struct ChunkAccumulator {
    private(set) var text: String = ""
    private var lower: String.Index?
    private var upper: String.Index?

    var isEmpty: Bool {
        text.isEmpty
    }

    var count: Int {
        text.count
    }

    var upperIndex: String.Index? {
        upper
    }

    mutating func extend(with addition: String, upper newUpper: String.Index) {
        text += addition
        upper = newUpper
    }

    mutating func reset(to newText: String, lower newLower: String.Index, upper newUpper: String.Index) {
        text = newText
        lower = newLower
        upper = newUpper
    }

    mutating func flush() -> RawPiece? {
        defer {
            text = ""
            lower = nil
            upper = nil
        }
        guard !text.isEmpty, let lower, let upper else { return nil }
        return RawPiece(text: text, lower: lower, upper: upper, withinSentence: false)
    }
}
