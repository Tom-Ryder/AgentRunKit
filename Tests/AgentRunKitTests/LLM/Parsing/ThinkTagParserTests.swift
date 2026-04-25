@testable import AgentRunKit
import Foundation
import Testing

struct ThinkTagParserBatchTests {
    @Test
    func noThinkTags() {
        let result = ThinkTagParser.extract(from: "Hello world")
        #expect(result.reasoning == "")
        #expect(result.content == "Hello world")
    }

    @Test
    func standardThinkBlock() {
        let result = ThinkTagParser.extract(from: "<think>reasoning</think>answer")
        #expect(result.reasoning == "reasoning")
        #expect(result.content == "answer")
    }

    @Test
    func emptyThinkBlock() {
        let result = ThinkTagParser.extract(from: "<think></think>answer")
        #expect(result.reasoning == "")
        #expect(result.content == "answer")
    }

    @Test
    func thinkBlockOnly() {
        let result = ThinkTagParser.extract(from: "<think>reasoning</think>")
        #expect(result.reasoning == "reasoning")
        #expect(result.content == "")
    }

    @Test
    func unclosedThinkBlock() {
        let result = ThinkTagParser.extract(from: "<think>reasoning")
        #expect(result.reasoning == "reasoning")
        #expect(result.content == "")
    }

    @Test
    func leadingWhitespace() {
        let result = ThinkTagParser.extract(from: "  <think>reasoning</think>answer")
        #expect(result.reasoning == "reasoning")
        #expect(result.content == "answer")
    }

    @Test
    func nonWhitespaceBeforeTag() {
        let result = ThinkTagParser.extract(from: "abc<think>def</think>ghi")
        #expect(result.reasoning == "")
        #expect(result.content == "abc<think>def</think>ghi")
    }

    @Test
    func whitespaceAroundContent() {
        let result = ThinkTagParser.extract(from: "<think>\n  reasoning  \n</think>\n\ncontent")
        #expect(result.reasoning == "reasoning  \n")
        #expect(result.content == "content")
    }

    @Test
    func emptyInput() {
        let result = ThinkTagParser.extract(from: "")
        #expect(result.reasoning == "")
        #expect(result.content == "")
    }

    @Test
    func bareOpenTag() {
        let result = ThinkTagParser.extract(from: "<think>")
        #expect(result.reasoning == "")
        #expect(result.content == "")
    }

    @Test
    func nestedThinkTag() {
        let result = ThinkTagParser.extract(from: "<think>a<think>b</think>c")
        #expect(result.reasoning == "a<think>b")
        #expect(result.content == "c")
    }
}

struct ThinkTagParserStreamingTests {
    private func feedChunks(_ chunks: [String]) -> (reasoning: String, content: String) {
        var parser = ThinkTagParser()
        var reasoning = ""
        var content = ""
        for chunk in chunks {
            let result = parser.addContent(chunk)
            reasoning += result.reasoning
            content += result.content
        }
        let final = parser.finalize()
        reasoning += final.reasoning
        content += final.content
        return (reasoning, content)
    }

    @Test
    func streamCleanSplit() {
        let result = feedChunks(["<think>", "reasoning", "</think>", "answer"])
        #expect(result.reasoning == "reasoning")
        #expect(result.content == "answer")
    }

    @Test
    func streamPartialOpenTag() {
        let result = feedChunks(["<th", "ink>reason</think>answer"])
        #expect(result.reasoning == "reason")
        #expect(result.content == "answer")
    }

    @Test
    func streamPartialCloseTag() {
        let result = feedChunks(["<think>abc</th", "ink>def"])
        #expect(result.reasoning == "abc")
        #expect(result.content == "def")
    }

    @Test
    func streamFalsePartialClose() {
        let result = feedChunks(["<think>abc</th", "ing>def</think>ghi"])
        #expect(result.reasoning == "abc</thing>def")
        #expect(result.content == "ghi")
    }

    @Test
    func streamNoTags() {
        let result = feedChunks(["Hello", " world"])
        #expect(result.reasoning == "")
        #expect(result.content == "Hello world")
    }

    @Test
    func streamLeadingWhitespace() {
        let result = feedChunks(["  ", "<think>r</think>a"])
        #expect(result.reasoning == "r")
        #expect(result.content == "a")
    }

    @Test
    func streamWhitespaceAfterClose() {
        let result = feedChunks(["<think>r</think>", "\n\n", "a"])
        #expect(result.reasoning == "r")
        #expect(result.content == "a")
    }

    @Test
    func streamCloseTagInContent() {
        let result = feedChunks(["<think>r</think>content with </think> in it"])
        #expect(result.reasoning == "r")
        #expect(result.content == "content with </think> in it")
    }
}

struct ThinkTagParserFinalizeTests {
    @Test
    func finalizeLookingForOpen() {
        var parser = ThinkTagParser()
        _ = parser.addContent("<th")
        let result = parser.finalize()
        #expect(result.reasoning == "")
        #expect(result.content == "<th")
    }

    @Test
    func finalizeEatingOpenWhitespace() {
        var parser = ThinkTagParser()
        _ = parser.addContent("<think>\n")
        let result = parser.finalize()
        #expect(result.reasoning == "")
        #expect(result.content == "")
    }

    @Test
    func finalizeThinking() {
        var parser = ThinkTagParser()
        let addResult = parser.addContent("<think>partial</t")
        let result = parser.finalize()
        #expect(addResult.reasoning + result.reasoning == "partial</t")
        #expect(addResult.content + result.content == "")
        #expect(result.reasoning == "</t")
    }

    @Test
    func finalizeThinkingWithOverlap() {
        var parser = ThinkTagParser()
        let addResult = parser.addContent("<think>abc</th")
        let result = parser.finalize()
        #expect(addResult.reasoning + result.reasoning == "abc</th")
        #expect(addResult.content + result.content == "")
        #expect(result.reasoning == "</th")
    }

    @Test
    func finalizeEatingCloseWhitespace() {
        var parser = ThinkTagParser()
        _ = parser.addContent("<think>r</think>  ")
        let result = parser.finalize()
        #expect(result.reasoning == "")
        #expect(result.content == "")
    }
}

struct ThinkTagParserOverlapTests {
    @Test
    func overlapPartialMatch() {
        #expect(ThinkTagParser.overlap("abc</th", "</think>") == 4)
    }

    @Test
    func overlapNoMatch() {
        #expect(ThinkTagParser.overlap("abcdef", "</think>") == 0)
    }

    @Test
    func overlapFullMatch() {
        #expect(ThinkTagParser.overlap("abc</think>", "</think>") == 8)
    }
}

struct ThinkTagParserCustomDelimiterTests {
    @Test
    func customTags() {
        let result = ThinkTagParser.extract(
            from: "◁think▷reasoning◁/think▷answer",
            openTag: "◁think▷",
            closeTag: "◁/think▷"
        )
        #expect(result.reasoning == "reasoning")
        #expect(result.content == "answer")
    }

    @Test
    func customTagsStreaming() {
        var parser = ThinkTagParser(openTag: "◁think▷", closeTag: "◁/think▷")
        var reasoning = ""
        var content = ""
        for chunk in ["◁thi", "nk▷reas", "oning◁/thi", "nk▷answer"] {
            let result = parser.addContent(chunk)
            reasoning += result.reasoning
            content += result.content
        }
        let final = parser.finalize()
        reasoning += final.reasoning
        content += final.content
        #expect(reasoning == "reasoning")
        #expect(content == "answer")
    }

    @Test
    func defaultTagsUnchanged() {
        let parser = ThinkTagParser()
        #expect(parser.openTag == "<think>")
        #expect(parser.closeTag == "</think>")
    }
}

struct ThinkTagParserPropertyTests {
    @Test
    func chunkBoundaryInvariant() {
        let inputs = [
            "<think>reasoning</think>content",
            "no tags here",
            "<think>unclosed",
            "  <think>ws</think>  result",
            "<think>a<think>b</think>c",
            "<think>\n  spaced  \n</think>\n\nout"
        ]
        for input in inputs {
            let expected = ThinkTagParser.extract(from: input)

            var parser = ThinkTagParser()
            var reasoning = ""
            var content = ""
            for char in input {
                let result = parser.addContent(String(char))
                reasoning += result.reasoning
                content += result.content
            }
            let final = parser.finalize()
            reasoning += final.reasoning
            content += final.content

            #expect(reasoning == expected.reasoning, "Reasoning mismatch for: \(input)")
            #expect(content == expected.content, "Content mismatch for: \(input)")
        }
    }
}
