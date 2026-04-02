@testable import AgentRunKit
import Foundation
import Testing

private enum StreamingLimitTestError: Error {
    case nonUTF8
}

private struct StreamingLimitEchoParams: Codable, SchemaProviding {
    let message: String

    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct StreamingLimitEchoOutput: Codable {
    let echoed: String
}

private func encodedEchoOutput(_ message: String) throws -> String {
    let data = try JSONEncoder().encode(StreamingLimitEchoOutput(echoed: message))
    guard let content = String(bytes: data, encoding: .utf8) else {
        throw StreamingLimitTestError.nonUTF8
    }
    return content
}

private func extractToolContent(_ messages: [ChatMessage]) -> String? {
    for message in messages {
        if case let .tool(_, _, content) = message {
            return content
        }
    }
    return nil
}

struct AgentStreamingToolResultLimitTests {
    @Test
    func streamPerToolTruncationAppliesToEventHistoryAndNextIterationInput() async throws {
        let longOutput = String(repeating: "X", count: 200)
        let echoTool = try Tool<StreamingLimitEchoParams, StreamingLimitEchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes",
            maxResultCharacters: 50,
            executor: { params, _ in StreamingLimitEchoOutput(echoed: params.message) }
        )
        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "\#(longOutput)"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = CapturingStreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let config = AgentConfiguration(maxIterations: 5, maxToolResultCharacters: 1000)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            events.append(event)
        }

        let expected = try ContextCompactor.truncateToolResult(
            encodedEchoOutput(longOutput),
            maxCharacters: 50
        )
        let toolCompleted = events.first { event in
            if case let .toolCallCompleted(_, name, _) = event.kind { name == "echo" } else { false }
        }
        guard case let .toolCallCompleted(_, _, result) = toolCompleted?.kind else {
            Issue.record("Expected toolCallCompleted event")
            return
        }
        #expect(result.content == expected)

        guard case let .finished(_, content, _, history) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(content == "done")
        #expect(extractToolContent(history) == expected)

        let allCapturedMessages = await client.allCapturedMessages
        #expect(allCapturedMessages.count == 2)
        #expect(extractToolContent(allCapturedMessages[1]) == expected)
    }

    @Test
    func streamPerToolLimitCanExceedGlobalDefault() async throws {
        let longOutput = String(repeating: "Y", count: 200)
        let echoTool = try Tool<StreamingLimitEchoParams, StreamingLimitEchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes",
            maxResultCharacters: 100_000,
            executor: { params, _ in StreamingLimitEchoOutput(echoed: params.message) }
        )
        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo"),
            .toolCallDelta(index: 0, arguments: #"{"message": "\#(longOutput)"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish"),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let config = AgentConfiguration(maxIterations: 5, maxToolResultCharacters: 50)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            events.append(event)
        }

        let expected = try encodedEchoOutput(longOutput)
        let toolCompleted = events.first { event in
            if case let .toolCallCompleted(_, name, _) = event.kind { name == "echo" } else { false }
        }
        guard case let .toolCallCompleted(_, _, result) = toolCompleted?.kind else {
            Issue.record("Expected toolCallCompleted event")
            return
        }
        #expect(result.content == expected)

        guard case let .finished(_, _, _, history) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(extractToolContent(history) == expected)
    }
}
