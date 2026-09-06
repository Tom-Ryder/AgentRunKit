@testable import AgentRunKit
import Foundation
import Testing

@Suite(.tags(.provider, .wireFormat))
struct AnthropicContextCompactionTests {
    @Test(arguments: AnthropicContextExecution.allCases, [0.85, 0.86])
    func cacheAndThinkingDriveNextIterationCompaction(
        execution: AnthropicContextExecution, threshold: Double
    ) async throws {
        let shouldCompact = threshold == 0.85
        var responses = try [AnthropicContextReply.tool(id: "call_1").response(
            execution: execution, usage: anthropicCachedContextUsage
        )]
        if shouldCompact {
            try responses.append(AnthropicContextReply.text("Saved progress").response(
                execution: .blocking, usage: nil
            ))
        }
        try responses.append(AnthropicContextReply.text("done").response(execution: execution, usage: nil))
        try await withAnthropicContextClient(responses: responses) { client, url in
            let agent = try Agent(
                client: client, tools: [makeAnthropicContextTool()],
                configuration: AgentConfiguration(maxIterations: 2, compactionThreshold: threshold)
            )
            switch execution {
            case .blocking:
                let result = try await agent.run(userMessage: "Work", context: EmptyContext())
                #expect(result.content == "done")
                #expect(result.iterations == 2)
                #expect(result.totalTokenUsage.total == 850)
            case .streaming:
                var events: [StreamEvent.Kind] = []
                for try await event in agent.stream(userMessage: "Work", context: EmptyContext()) {
                    events.append(event.kind)
                }
                let compactions = events.filter { if case .compacted = $0 { true } else { false } }
                #expect(compactions == (shouldCompact ? [.compacted(totalTokens: 850, windowSize: 1000)] : []))
                guard case let .finished(usage, content, reason, _) = events.last else {
                    Issue.record("Expected finished event")
                    return
                }
                #expect(usage.total == 850)
                #expect(content == "done")
                #expect(reason == .completed)
            }
            let bodies = HTTPTestURLProtocol.recordedBodyData(for: url)
            try #require(bodies.count == (shouldCompact ? 3 : 2))
            let requests = try bodies.map { try JSONDecoder().decode([String: JSONValue].self, from: $0) }
            #expect(requests[0]["messages"] == .array([.object([
                "role": .string("user"), "content": .string("Work")
            ])]))
            #expect(requests[0]["tools"] != nil)
            #expect(requests.last?["tools"] != nil)
            guard case let .array(messages) = requests.last?["messages"] else {
                Issue.record("Expected captured Anthropic messages")
                return
            }
            #expect(messages.count == (shouldCompact ? 5 : 3))
            #expect(messages.last == .object([
                "role": .string("user"), "content": .array([.object([
                    "type": .string("tool_result"), "tool_use_id": .string("call_1"), "content": .string("{}")
                ])])
            ]))
            if shouldCompact {
                #expect(requests[1]["tools"] == nil)
                #expect(requests[1]["stream"] == nil)
                guard case let .object(bridge) = messages[1], case let .string(content) = bridge["content"] else {
                    Issue.record("Expected compaction summary in the next request")
                    return
                }
                #expect(bridge["role"] == .string("user"))
                #expect(content.contains("Saved progress"))
            }
        }
    }

    @Test(arguments: AnthropicContextExecution.allCases)
    func unavailableUsageRetainsBlockingEstimateAndClearsStreamingEstimate(
        execution: AnthropicContextExecution
    ) async throws {
        var responses = try [
            AnthropicContextReply.tool(id: "call_1").response(execution: execution, usage: anthropicCachedContextUsage),
            AnthropicContextReply.text("First summary").response(execution: .blocking, usage: nil),
            AnthropicContextReply.tool(id: "call_2").response(execution: execution, usage: nil)
        ]
        if execution == .blocking {
            try responses.append(AnthropicContextReply.text("Second summary").response(
                execution: .blocking, usage: nil
            ))
        }
        try responses.append(AnthropicContextReply.text("done").response(execution: execution, usage: nil))
        try await withAnthropicContextClient(responses: responses) { client, url in
            let agent = try Agent(
                client: client, tools: [makeAnthropicContextTool()],
                configuration: AgentConfiguration(maxIterations: 3, compactionThreshold: 0.85)
            )
            let history: [ChatMessage]
            switch execution {
            case .blocking:
                let result = try await agent.run(userMessage: "Work", context: EmptyContext())
                #expect(result.content == "done")
                #expect(result.iterations == 3)
                #expect(result.totalTokenUsage.total == 850)
                history = result.history
            case .streaming:
                var events: [StreamEvent.Kind] = []
                for try await event in agent.stream(userMessage: "Work", context: EmptyContext()) {
                    events.append(event.kind)
                }
                #expect(events.count(where: { if case .compacted = $0 { true } else { false } }) == 1)
                guard case let .finished(usage, content, reason, finalHistory) = events.last else {
                    Issue.record("Expected finished event")
                    return
                }
                #expect(usage.total == 850)
                #expect(content == "done")
                #expect(reason == .completed)
                history = finalHistory
            }
            let summaries = history.compactMap { message -> String? in
                guard case let .user(content) = message else { return nil }
                return content
            }
            #expect(summaries.contains { $0.contains("First summary") })
            #expect(summaries.contains { $0.contains("Second summary") } == (execution == .blocking))
            let bodies = HTTPTestURLProtocol.recordedBodyData(for: url)
            try #require(bodies.count == (execution == .blocking ? 5 : 4))
            let requests = try bodies.map { try JSONDecoder().decode([String: JSONValue].self, from: $0) }
            #expect(requests.count(where: { $0["tools"] == nil }) == (execution == .blocking ? 2 : 1))
            guard case let .array(messages) = requests.last?["messages"] else {
                Issue.record("Expected captured Anthropic messages")
                return
            }
            #expect(messages.count == (execution == .blocking ? 6 : 7))
            #expect(messages.last == .object([
                "role": .string("user"), "content": .array([.object([
                    "type": .string("tool_result"), "tool_use_id": .string("call_2"), "content": .string("{}")
                ])])
            ]))
        }
    }
}
