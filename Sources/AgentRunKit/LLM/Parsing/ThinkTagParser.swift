import Foundation

/// Extracts reasoning content from think-tag delimited text.
public struct ThinkTagParser: Sendable {
    private enum State {
        case lookingForOpen
        case eatingOpenWhitespace
        case thinking
        case eatingCloseWhitespace
        case content
    }

    let openTag: String
    let closeTag: String

    private var state: State = .lookingForOpen
    private var accumulator: String = ""

    public init(openTag: String = "<think>", closeTag: String = "</think>") {
        self.openTag = openTag
        self.closeTag = closeTag
    }

    public mutating func addContent(_ text: String) -> (reasoning: String, content: String) {
        accumulator += text
        var reasoning = ""
        var content = ""
        while eat(&reasoning, &content) {}
        return (reasoning, content)
    }

    public mutating func finalize() -> (reasoning: String, content: String) {
        switch state {
        case .lookingForOpen:
            let content = accumulator
            accumulator = ""
            return ("", content)
        case .eatingOpenWhitespace:
            accumulator = ""
            return ("", "")
        case .thinking:
            let reasoning = accumulator
            accumulator = ""
            return (reasoning, "")
        case .eatingCloseWhitespace:
            accumulator = ""
            return ("", "")
        case .content:
            return ("", "")
        }
    }

    public static func extract(
        from text: String,
        openTag: String = "<think>",
        closeTag: String = "</think>"
    ) -> (reasoning: String, content: String) {
        var parser = ThinkTagParser(openTag: openTag, closeTag: closeTag)
        let partial = parser.addContent(text)
        let final = parser.finalize()
        return (partial.reasoning + final.reasoning, partial.content + final.content)
    }

    private mutating func eat(_ reasoning: inout String, _ content: inout String) -> Bool {
        switch state {
        case .lookingForOpen:
            return eatLookingForOpen(&content)
        case .eatingOpenWhitespace:
            return eatOpenWhitespace()
        case .thinking:
            return eatThinking(&reasoning)
        case .eatingCloseWhitespace:
            return eatCloseWhitespace()
        case .content:
            content += accumulator
            accumulator = ""
            return false
        }
    }

    private mutating func eatLookingForOpen(_ content: inout String) -> Bool {
        let trimmed = accumulator.drop(while: { $0.isWhitespace })
        if trimmed.isEmpty {
            return false
        }
        if trimmed.hasPrefix(openTag) {
            let afterTag = trimmed.dropFirst(openTag.count)
            accumulator = String(afterTag)
            state = .eatingOpenWhitespace
            return true
        }
        if openTag.hasPrefix(trimmed) {
            return false
        }
        content += accumulator
        accumulator = ""
        state = .content
        return true
    }

    private mutating func eatOpenWhitespace() -> Bool {
        guard let firstNonWS = accumulator.firstIndex(where: { !$0.isWhitespace }) else {
            accumulator = ""
            return false
        }
        accumulator = String(accumulator[firstNonWS...])
        state = .thinking
        return true
    }

    private mutating func eatThinking(_ reasoning: inout String) -> Bool {
        guard let closeRange = accumulator.range(of: closeTag) else {
            let overlapLen = Self.overlap(accumulator, closeTag)
            if overlapLen > 0 {
                let splitIndex = accumulator.index(accumulator.endIndex, offsetBy: -overlapLen)
                reasoning += accumulator[..<splitIndex]
                accumulator = String(accumulator[splitIndex...])
            } else {
                reasoning += accumulator
                accumulator = ""
            }
            return false
        }
        reasoning += accumulator[..<closeRange.lowerBound]
        accumulator = String(accumulator[closeRange.upperBound...])
        state = .eatingCloseWhitespace
        return true
    }

    private mutating func eatCloseWhitespace() -> Bool {
        guard let firstNonWS = accumulator.firstIndex(where: { !$0.isWhitespace }) else {
            accumulator = ""
            return false
        }
        accumulator = String(accumulator[firstNonWS...])
        state = .content
        return true
    }

    static func overlap(_ buffer: String, _ tag: String) -> Int {
        let bufChars = Array(buffer)
        let tagChars = Array(tag)
        let maxPossible = min(bufChars.count, tagChars.count)
        for length in stride(from: maxPossible, through: 1, by: -1) {
            let suffix = bufChars[(bufChars.count - length)...]
            let prefix = tagChars[..<length]
            if suffix.elementsEqual(prefix) {
                return length
            }
        }
        return 0
    }
}
