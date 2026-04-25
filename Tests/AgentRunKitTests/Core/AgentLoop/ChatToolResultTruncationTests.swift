@testable import AgentRunKit
import Foundation
import Testing

private struct ChatLimitedTool: AnyTool {
    typealias Context = EmptyContext

    let name: String
    let description = "Returns long output"
    let parametersSchema: JSONSchema = .object(properties: [:], required: [])
    let maxResultCharacters: Int?
    private let output: String

    init(name: String = "limited", maxResultCharacters: Int?, output: String) {
        self.name = name
        self.maxResultCharacters = maxResultCharacters
        self.output = output
    }

    func execute(arguments _: Data, context _: EmptyContext) async throws -> ToolResult {
        .success(output)
    }
}

private func extractToolContent(_ messages: [ChatMessage]) -> String? {
    for message in messages {
        if case let .tool(_, _, content) = message {
            return content
        }
    }
    return nil
}

struct ChatToolResultTruncationTests {
    @Test
    func chatPerToolTruncation() async throws {
        let longOutput = String(repeating: "A", count: 200)
        let tool = ChatLimitedTool(maxResultCharacters: 50, output: longOutput)

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "limited", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .content("Done"),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [tool], maxToolResultCharacters: 1000)

        var events: [StreamEvent] = []
        for try await event in chat.stream("Go", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompleted = events.first { event in
            if case let .toolCallCompleted(_, name, _) = event.kind { name == "limited" } else { false }
        }
        guard case let .toolCallCompleted(_, _, result) = toolCompleted?.kind else {
            Issue.record("Expected toolCallCompleted")
            return
        }
        let expected = ContextCompactor.truncateToolResult(longOutput, maxCharacters: 50)
        #expect(result.content == expected)
        #expect(result.content.count <= 50)
        guard case let .finished(_, _, _, history) = events.last?.kind else {
            Issue.record("Expected finished")
            return
        }
        #expect(extractToolContent(history) == expected)
    }

    @Test
    func chatGlobalFallback() async throws {
        let longOutput = String(repeating: "B", count: 200)
        let tool = ChatLimitedTool(maxResultCharacters: nil, output: longOutput)

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "limited", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .content("Done"),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [tool], maxToolResultCharacters: 50)

        var events: [StreamEvent] = []
        for try await event in chat.stream("Go", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompleted = events.first { event in
            if case let .toolCallCompleted(_, name, _) = event.kind { name == "limited" } else { false }
        }
        guard case let .toolCallCompleted(_, _, result) = toolCompleted?.kind else {
            Issue.record("Expected toolCallCompleted")
            return
        }
        let expected = ContextCompactor.truncateToolResult(longOutput, maxCharacters: 50)
        #expect(result.content == expected)
        #expect(result.content.count <= 50)
        guard case let .finished(_, _, _, history) = events.last?.kind else {
            Issue.record("Expected finished")
            return
        }
        #expect(extractToolContent(history) == expected)
    }

    @Test
    func chatNoTruncationWhenBothNil() async throws {
        let longOutput = String(repeating: "C", count: 200)
        let tool = ChatLimitedTool(maxResultCharacters: nil, output: longOutput)

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "limited", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .content("Done"),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [tool])

        var events: [StreamEvent] = []
        for try await event in chat.stream("Go", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompleted = events.first { event in
            if case let .toolCallCompleted(_, name, _) = event.kind { name == "limited" } else { false }
        }
        guard case let .toolCallCompleted(_, _, result) = toolCompleted?.kind else {
            Issue.record("Expected toolCallCompleted")
            return
        }
        #expect(result.content == longOutput)
        guard case let .finished(_, _, _, history) = events.last?.kind else {
            Issue.record("Expected finished")
            return
        }
        #expect(extractToolContent(history) == longOutput)
    }

    @Test
    func chatPerToolLimitCanExceedGlobalDefault() async throws {
        let longOutput = String(repeating: "D", count: 200)
        let tool = ChatLimitedTool(maxResultCharacters: 100_000, output: longOutput)

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "limited", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .content("Done"),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [tool], maxToolResultCharacters: 50)

        var events: [StreamEvent] = []
        for try await event in chat.stream("Go", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompleted = events.first { event in
            if case let .toolCallCompleted(_, name, _) = event.kind { name == "limited" } else { false }
        }
        guard case let .toolCallCompleted(_, _, result) = toolCompleted?.kind else {
            Issue.record("Expected toolCallCompleted")
            return
        }
        #expect(result.content == longOutput)
        guard case let .finished(_, _, _, history) = events.last?.kind else {
            Issue.record("Expected finished")
            return
        }
        #expect(extractToolContent(history) == longOutput)
    }
}
