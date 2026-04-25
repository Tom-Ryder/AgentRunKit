@testable import AgentRunKit
import Foundation
import Testing

private struct QueryParams: Codable, SchemaProviding {
    let query: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

struct SubAgentIterationHistoryTests {
    @Test
    func subAgentIterationCompletedHistoryIsScopedToSubAgent() async throws {
        let childDeltas: [StreamDelta] = [
            .content("child thinking"),
            .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "child result"}"#),
            .finished(usage: TokenUsage(input: 5, output: 5)),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_sub", name: "research", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"query": "find something"}"#),
            .finished(usage: TokenUsage(input: 10, output: 10)),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "parent done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        var subAgentHistories: [[ChatMessage]] = []
        var parentHistories: [[ChatMessage]] = []
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            switch event.kind {
            case let .iterationCompleted(_, _, history):
                parentHistories.append(history)
            case let .subAgentEvent(_, _, nestedEvent):
                if case let .iterationCompleted(_, _, history) = nestedEvent.kind {
                    subAgentHistories.append(history)
                }
            default:
                break
            }
        }

        #expect(subAgentHistories.count == 1)
        #expect(parentHistories.count == 2)

        let subHistory = subAgentHistories[0]
        guard case .user("find something") = subHistory.first else {
            Issue.record("Sub-agent history must start with its own user message")
            return
        }
        for message in subHistory {
            switch message {
            case let .user(text):
                #expect(text == "find something", "Parent user message leaked into sub-agent history")
            case let .assistant(assistant):
                #expect(
                    !assistant.toolCalls.contains(where: { $0.name == "research" }),
                    "Parent assistant turn that invoked the sub-agent leaked into the child history"
                )
            case let .tool(_, name, _):
                #expect(name != "research", "Parent tool result leaked into sub-agent history")
            case .system, .userMultimodal:
                continue
            }
        }
    }

    @Test
    func subAgentNestedHistoryStrippedWhenParentLimitConfigured() async throws {
        let childDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "child result"}"#),
            .finished(usage: TokenUsage(input: 5, output: 5)),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas])
        let childAgent = Agent<SubAgentContext<EmptyContext>>(client: childClient, tools: [])

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_sub", name: "research", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"query": "find something"}"#),
            .finished(usage: TokenUsage(input: 10, output: 10)),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "parent done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentConfig = AgentConfiguration(historyEmissionDepthLimit: 0)
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(
            client: parentClient, tools: [tool], configuration: parentConfig
        )

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        var subAgentHistories: [[ChatMessage]] = []
        var parentHistories: [[ChatMessage]] = []
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            switch event.kind {
            case let .iterationCompleted(_, _, history):
                parentHistories.append(history)
            case let .subAgentEvent(_, _, nestedEvent):
                if case let .iterationCompleted(_, _, history) = nestedEvent.kind {
                    subAgentHistories.append(history)
                }
            default:
                break
            }
        }

        #expect(subAgentHistories.count == 1)
        #expect(subAgentHistories[0].isEmpty)
        #expect(parentHistories.count == 2)
        for history in parentHistories {
            #expect(!history.isEmpty)
        }
    }

    @Test
    func subAgentDepthLimitOmitsNestedHistory() async throws {
        let childDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "child_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "child result"}"#),
            .finished(usage: TokenUsage(input: 5, output: 5)),
        ]
        let childClient = StreamingMockLLMClient(streamSequences: [childDeltas])
        let childConfig = AgentConfiguration(historyEmissionDepthLimit: 0)
        let childAgent = Agent<SubAgentContext<EmptyContext>>(
            client: childClient, tools: [], configuration: childConfig
        )

        let tool = try SubAgentTool<QueryParams, EmptyContext>(
            name: "research",
            description: "Research tool",
            agent: childAgent,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_sub", name: "research", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"query": "find something"}"#),
            .finished(usage: TokenUsage(input: 10, output: 10)),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "parent done"}"#),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        var subAgentHistories: [[ChatMessage]] = []
        var parentHistories: [[ChatMessage]] = []
        for try await event in parentAgent.stream(userMessage: "Go", context: ctx) {
            switch event.kind {
            case let .iterationCompleted(_, _, history):
                parentHistories.append(history)
            case let .subAgentEvent(_, _, nestedEvent):
                if case let .iterationCompleted(_, _, history) = nestedEvent.kind {
                    subAgentHistories.append(history)
                }
            default:
                break
            }
        }

        #expect(subAgentHistories.count == 1)
        #expect(subAgentHistories[0].isEmpty)

        #expect(parentHistories.count == 2)
        for history in parentHistories {
            #expect(!history.isEmpty)
        }
    }
}
