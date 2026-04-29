import Foundation
import NaturalLanguage

enum SentenceChunker {
    struct Chunk: Equatable {
        let text: String
        let sourceRange: Range<Int>
    }

    static func chunk(text: String, maxCharacters: Int) -> [Chunk] {
        precondition(maxCharacters >= 1, "maxCharacters must be at least 1")

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let trimShift = trimByteOffset(in: text)
        let sentenceRanges = enumerateSentences(trimmed)

        var chunks: [Chunk] = []
        var accumulator = ChunkAccumulator()

        for range in sentenceRanges {
            let sentence = trimmed[range]
            if sentence.count > maxCharacters {
                if let chunk = accumulator.flush(in: trimmed, shiftedBy: trimShift) {
                    chunks.append(chunk)
                }
                chunks.append(contentsOf: splitOversized(
                    sentence,
                    maxCharacters: maxCharacters,
                    trimmed: trimmed,
                    shiftedBy: trimShift
                ))
            } else if accumulator.text.count + sentence.count <= maxCharacters {
                accumulator.extend(
                    with: String(sentence),
                    lower: range.lowerBound,
                    upper: range.upperBound
                )
            } else {
                if let chunk = accumulator.flush(in: trimmed, shiftedBy: trimShift) {
                    chunks.append(chunk)
                }
                accumulator.reset(
                    to: String(sentence),
                    lower: range.lowerBound,
                    upper: range.upperBound
                )
            }
        }

        if let chunk = accumulator.flush(in: trimmed, shiftedBy: trimShift) {
            chunks.append(chunk)
        }

        return chunks
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

    private static func splitOversized(
        _ sentence: Substring,
        maxCharacters: Int,
        trimmed: String,
        shiftedBy trimShift: Int
    ) -> [Chunk] {
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true)
        var chunks: [Chunk] = []
        var accumulator = ChunkAccumulator()

        for word in words {
            if word.count > maxCharacters {
                if let chunk = accumulator.flush(in: trimmed, shiftedBy: trimShift) {
                    chunks.append(chunk)
                }
                chunks.append(contentsOf: splitAtCharacterBoundaries(
                    word,
                    maxCharacters: maxCharacters,
                    trimmed: trimmed,
                    shiftedBy: trimShift
                ))
                continue
            }

            let separator = accumulator.text.isEmpty ? "" : " "
            if accumulator.text.count + separator.count + word.count <= maxCharacters {
                accumulator.extend(
                    with: separator + word,
                    lower: word.startIndex,
                    upper: word.endIndex
                )
            } else {
                if let chunk = accumulator.flush(in: trimmed, shiftedBy: trimShift) {
                    chunks.append(chunk)
                }
                accumulator.reset(
                    to: String(word),
                    lower: word.startIndex,
                    upper: word.endIndex
                )
            }
        }

        if let chunk = accumulator.flush(in: trimmed, shiftedBy: trimShift) {
            chunks.append(chunk)
        }

        return chunks
    }

    private static func splitAtCharacterBoundaries(
        _ word: Substring,
        maxCharacters: Int,
        trimmed: String,
        shiftedBy trimShift: Int
    ) -> [Chunk] {
        var chunks: [Chunk] = []
        var startIndex = word.startIndex
        while startIndex < word.endIndex {
            let endIndex = word.index(startIndex, offsetBy: maxCharacters, limitedBy: word.endIndex) ?? word.endIndex
            chunks.append(Chunk(
                text: String(word[startIndex ..< endIndex]),
                sourceRange: sourceRange(lower: startIndex, upper: endIndex, in: trimmed, shiftedBy: trimShift)
            ))
            startIndex = endIndex
        }
        return chunks
    }

    fileprivate static func sourceRange(
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

private struct ChunkAccumulator {
    private(set) var text: String = ""
    private var lower: String.Index?
    private var upper: String.Index?

    mutating func extend(with addition: String, lower newLower: String.Index, upper newUpper: String.Index) {
        if text.isEmpty { lower = newLower }
        text += addition
        upper = newUpper
    }

    mutating func reset(to newText: String, lower newLower: String.Index, upper newUpper: String.Index) {
        text = newText
        lower = newLower
        upper = newUpper
    }

    mutating func flush(in trimmed: String, shiftedBy trimShift: Int) -> SentenceChunker.Chunk? {
        defer {
            text = ""
            lower = nil
            upper = nil
        }
        guard !text.isEmpty, let lower, let upper else { return nil }
        return SentenceChunker.Chunk(
            text: text,
            sourceRange: SentenceChunker.sourceRange(
                lower: lower, upper: upper, in: trimmed, shiftedBy: trimShift
            )
        )
    }
}
