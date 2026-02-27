import Foundation
import NaturalLanguage

enum SentenceChunker {
    static func chunk(text: String, maxCharacters: Int) -> [String] {
        precondition(maxCharacters >= 1, "maxCharacters must be at least 1")

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let sentences = enumerateSentences(trimmed)
        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            if sentence.count > maxCharacters {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: splitOversized(sentence, maxCharacters: maxCharacters))
            } else if current.count + sentence.count <= maxCharacters {
                current += sentence
            } else {
                if !current.isEmpty {
                    chunks.append(current)
                }
                current = sentence
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private static func enumerateSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            sentences.append(String(text[range]))
            return true
        }
        return sentences
    }

    private static func splitOversized(_ text: String, maxCharacters: Int) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var chunks: [String] = []
        var current = ""

        for word in words {
            let wordStr = String(word)

            if wordStr.count > maxCharacters {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: splitAtCharacterBoundaries(wordStr, maxCharacters: maxCharacters))
                continue
            }

            let separator = current.isEmpty ? "" : " "
            if current.count + separator.count + wordStr.count <= maxCharacters {
                current += separator + wordStr
            } else {
                if !current.isEmpty {
                    chunks.append(current)
                }
                current = wordStr
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private static func splitAtCharacterBoundaries(_ text: String, maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var startIndex = text.startIndex
        while startIndex < text.endIndex {
            let endIndex = text.index(startIndex, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[startIndex ..< endIndex]))
            startIndex = endIndex
        }
        return chunks
    }
}
