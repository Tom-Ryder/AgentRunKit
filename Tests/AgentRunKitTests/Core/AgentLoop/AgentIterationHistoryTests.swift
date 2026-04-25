@testable import AgentRunKit
import Foundation
import Testing

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

struct AgentIterationHistoryTests {
    @Test
    func iterationCompletedHistoryReflectsPostAppendSnapshot() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )

        let iteration1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message": "first"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let iteration2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [iteration1, iteration2])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var histories: [[ChatMessage]] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case let .iterationCompleted(_, _, history) = event.kind {
                histories.append(history)
            }
        }

        #expect(histories.count == 2)

        guard case let .assistant(iter1Assistant) = histories[0].last else {
            Issue.record("Iteration 1 history does not end with an assistant turn")
            return
        }
        #expect(iter1Assistant.toolCalls.contains(where: { $0.name == "echo" }))

        guard case let .assistant(iter2Assistant) = histories[1].last else {
            Issue.record("Iteration 2 history does not end with an assistant turn")
            return
        }
        #expect(iter2Assistant.toolCalls.contains(where: { $0.name == "finish" }))
    }

    @Test
    func iterationCompletedHistoryGrowsMonotonically() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )

        let iteration1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message": "x"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let iteration2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]

        let client = StreamingMockLLMClient(streamSequences: [iteration1, iteration2])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var histories: [[ChatMessage]] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case let .iterationCompleted(_, _, history) = event.kind {
                histories.append(history)
            }
        }

        #expect(histories.count == 2)
        #expect(histories[0].count == 2)
        #expect(histories[1].count == 4)
        for index in 0 ..< histories[0].count {
            #expect(histories[0][index] == histories[1][index])
        }
        if case .user("Go") = histories[0][0] {} else {
            Issue.record("Iteration 1 history must start with the user message")
        }
        guard case let .assistant(iter1Assistant) = histories[0][1] else {
            Issue.record("Iteration 1 history must end with the iteration-1 assistant turn")
            return
        }
        #expect(iter1Assistant.toolCalls.contains(where: { $0.name == "echo" }))
        if case let .tool(_, name, _) = histories[1][2] {
            #expect(name == "echo")
        } else {
            Issue.record("Iteration 2 history must include the echo tool result before the assistant turn")
        }
        guard case let .assistant(iter2Assistant) = histories[1][3] else {
            Issue.record("Iteration 2 history must end with the iteration-2 assistant turn")
            return
        }
        #expect(iter2Assistant.toolCalls.contains(where: { $0.name == "finish" }))
    }

    @Test
    func iterationCompletedHistoryIsFullWhenLimitConfiguredOnContextWithoutDepth() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let config = AgentConfiguration(historyEmissionDepthLimit: 0)
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        var histories: [[ChatMessage]] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case let .iterationCompleted(_, _, history) = event.kind {
                histories.append(history)
            }
        }

        #expect(histories.count == 1)
        #expect(histories[0].count == 2)
        if case .user("Go") = histories[0][0] {} else {
            Issue.record("History must start with the user message even when a depth limit is set")
        }
    }

    @Test
    func iterationCompletedHistoryRespectsDepthLimit() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let config = AgentConfiguration(historyEmissionDepthLimit: 0)
        let agent = Agent<SubAgentContext<EmptyContext>>(
            client: client, tools: [], configuration: config
        )
        let depthOneContext = SubAgentContext(inner: EmptyContext(), maxDepth: 3, currentDepth: 1)

        var histories: [[ChatMessage]] = []
        for try await event in agent.stream(userMessage: "Go", context: depthOneContext) {
            if case let .iterationCompleted(_, _, history) = event.kind {
                histories.append(history)
            }
        }

        #expect(histories.count == 1)
        #expect(histories[0].isEmpty)
    }
}
