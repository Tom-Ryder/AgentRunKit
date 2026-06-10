@testable import AgentRunKit
import Testing

struct SSEParserTests {
    @Test
    func emitsPayloadWithSpace() {
        var parser = SSEEventParser()
        #expect(parser.appendLine(#"data: {"content":"hello"}"#) == nil)
        #expect(parser.appendLine("")?.data == #"{"content":"hello"}"#)
    }

    @Test
    func emitsPayloadWithoutSpace() {
        var parser = SSEEventParser()
        #expect(parser.appendLine(#"data:{"content":"hello"}"#) == nil)
        #expect(parser.appendLine("")?.data == #"{"content":"hello"}"#)
    }

    @Test
    func preservesDoneMarkerWithSpace() {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data: [DONE]") == nil)
        #expect(parser.appendLine("")?.data == "[DONE]")
    }

    @Test
    func preservesDoneMarkerWithoutSpace() {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data:[DONE]") == nil)
        #expect(parser.appendLine("")?.data == "[DONE]")
    }

    @Test
    func aggregatesMultilineDataWithEventMetadata() {
        var parser = SSEEventParser()
        #expect(parser.appendLine("event: message") == nil)
        #expect(parser.appendLine("id: 42") == nil)
        #expect(parser.appendLine("retry: 1000") == nil)
        #expect(parser.appendLine("data: first") == nil)
        #expect(parser.appendLine(": ignored") == nil)
        #expect(parser.appendLine("data: second") == nil)
        let event = parser.appendLine("")

        #expect(event == SSEEvent(event: "message", data: "first\nsecond", id: "42", retry: 1000))
    }

    @Test
    func flushesFinalEventAtEOF() {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data: [DONE]") == nil)
        #expect(parser.finish()?.data == "[DONE]")
    }

    @Test
    func ignoresCommentOnlyEventsAndMalformedRetry() {
        var parser = SSEEventParser()
        #expect(parser.appendLine(": comment") == nil)
        #expect(parser.appendLine("retry: nope") == nil)
        #expect(parser.appendLine("") == nil)

        #expect(parser.appendLine("data: payload") == nil)
        #expect(parser.appendLine("") == SSEEvent(event: nil, data: "payload", id: nil, retry: nil))
    }

    @Test
    func ignoresNonDataEventWithoutDispatch() {
        var parser = SSEEventParser()
        #expect(parser.appendLine(": comment") == nil)
        #expect(parser.appendLine("event: message") == nil)
        #expect(parser.appendLine("") == nil)
        #expect(parser.appendLine("id: 123") == nil)
        #expect(parser.finish() == nil)
    }

    @Test
    func preservesEmptyDataEvents() {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data:") == nil)
        #expect(parser.appendLine("") == SSEEvent(event: nil, data: "", id: nil, retry: nil))
    }
}
