@testable import AgentRunKit
import Foundation
import Testing

struct ContextBudgetPhaseVisibilityTests {
    @Test func visibilityAppendedToLastToolResult() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(enableVisibility: true),
            windowSize: 10000
        )
        var messages: [ChatMessage] = [
            .assistant(AssistantMessage(content: "thinking")),
            .tool(id: "call_1", name: "search", content: "result data"),
        ]
        _ = phase.afterResponse(usage: TokenUsage(input: 3000, output: 500), messages: &messages)

        if case let .tool(_, _, content) = messages[1] {
            #expect(content.contains("[Token usage:"))
            #expect(content.hasPrefix("result data"))
        } else {
            Issue.record("Expected tool message at index 1")
        }
    }

    @Test func visibilityAsUserMessageWhenNoToolResults() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(enableVisibility: true),
            windowSize: 10000
        )
        var messages: [ChatMessage] = [
            .user("hello"),
            .assistant(AssistantMessage(content: "hi")),
        ]
        _ = phase.afterResponse(usage: TokenUsage(input: 1000, output: 200), messages: &messages)

        #expect(messages.count == 3)
        if case let .user(content) = messages[2] {
            #expect(content.contains("[Token usage:"))
        } else {
            Issue.record("Expected user message at index 2")
        }
    }

    @Test func visibilityDoesNotRewriteEarlierToolResults() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(enableVisibility: true),
            windowSize: 10000
        )
        var messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "old result"),
            .assistant(AssistantMessage(content: "thinking")),
        ]
        _ = phase.afterResponse(usage: TokenUsage(input: 1000, output: 200), messages: &messages)

        if case let .tool(_, _, content) = messages[0] {
            #expect(content == "old result")
        } else {
            Issue.record("Expected tool message at index 0")
        }
        if case let .user(content) = messages[2] {
            #expect(content.contains("[Token usage:"))
        } else {
            Issue.record("Expected user message at index 2")
        }
    }

    @Test func visibilityDisabledWhenNotConfigured() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(enableVisibility: false),
            windowSize: 10000
        )
        var messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "data"),
        ]
        _ = phase.afterResponse(usage: TokenUsage(input: 3000, output: 500), messages: &messages)

        if case let .tool(_, _, content) = messages[0] {
            #expect(!content.contains("[Token usage:"))
        }
        #expect(messages.count == 1)
    }

    @Test func customVisibilityFormat() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(enableVisibility: true, visibilityFormat: .custom("BUDGET: {usage}/{window}")),
            windowSize: 10000
        )
        var messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "data"),
        ]
        _ = phase.afterResponse(usage: TokenUsage(input: 5000, output: 1000), messages: &messages)

        if case let .tool(_, _, content) = messages[0] {
            #expect(content.contains("BUDGET: 6,000/10,000"))
        } else {
            Issue.record("Expected tool message")
        }
    }

    @Test func visibilityTargetsLastToolMessageNotFirst() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(enableVisibility: true),
            windowSize: 10000
        )
        var messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "first result"),
            .tool(id: "call_2", name: "search", content: "second result"),
        ]
        _ = phase.afterResponse(usage: TokenUsage(input: 3000, output: 500), messages: &messages)

        if case let .tool(_, _, content) = messages[0] {
            #expect(!content.contains("[Token usage:"))
        } else {
            Issue.record("Expected tool message at index 0")
        }
        if case let .tool(_, _, content) = messages[1] {
            #expect(content.contains("[Token usage:"))
            #expect(content.hasPrefix("second result"))
        } else {
            Issue.record("Expected tool message at index 1")
        }
    }
}

struct ContextBudgetPhaseAdvisoryTests {
    @Test func advisoryFiresOnSoftThresholdCrossing() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(softThreshold: 0.75),
            windowSize: 1000
        )
        var messages: [ChatMessage] = []
        let result = phase.afterResponse(usage: TokenUsage(input: 700, output: 100), messages: &messages)

        #expect(result.advisoryEmitted)
        #expect(messages.contains { if case let .user(content) = $0 { content.contains("advisory") } else { false } })
    }

    @Test func advisoryDoesNotRepeatAboveThreshold() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(softThreshold: 0.75),
            windowSize: 1000
        )
        var messages: [ChatMessage] = []
        _ = phase.afterResponse(usage: TokenUsage(input: 700, output: 100), messages: &messages)

        var messages2: [ChatMessage] = []
        let result2 = phase.afterResponse(usage: TokenUsage(input: 750, output: 100), messages: &messages2)

        #expect(!result2.advisoryEmitted)
        #expect(messages2.isEmpty)
    }

    @Test func advisoryRearmsAfterDropBelowThenCrossesAgain() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(softThreshold: 0.75),
            windowSize: 1000
        )

        var firstMessages: [ChatMessage] = []
        let firstResult = phase.afterResponse(usage: TokenUsage(input: 700, output: 100), messages: &firstMessages)
        #expect(firstResult.advisoryEmitted)

        var dropMessages: [ChatMessage] = []
        _ = phase.afterResponse(usage: TokenUsage(input: 300, output: 100), messages: &dropMessages)

        var rearmMessages: [ChatMessage] = []
        let rearmResult = phase.afterResponse(usage: TokenUsage(input: 700, output: 100), messages: &rearmMessages)
        #expect(rearmResult.advisoryEmitted)
    }

    @Test func advisoryNotEmittedWhenNoSoftThreshold() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(),
            windowSize: 1000
        )
        var messages: [ChatMessage] = []
        let result = phase.afterResponse(usage: TokenUsage(input: 900, output: 100), messages: &messages)

        #expect(!result.advisoryEmitted)
    }

    @Test func advisoryWithoutPruneSuggestsFinalAnswerOnly() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(softThreshold: 0.75, enablePruneTool: false),
            windowSize: 1000
        )
        var messages: [ChatMessage] = []
        _ = phase.afterResponse(usage: TokenUsage(input: 700, output: 100), messages: &messages)

        guard case let .user(content) = messages.last else {
            Issue.record("Expected advisory user message")
            return
        }
        #expect(content.contains("Provide your final answer"))
        #expect(!content.contains("prune_context"))
    }

    @Test func visibilityAndAdvisoryShareOneUserMessageWhenNoToolResults() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(softThreshold: 0.75, enableVisibility: true),
            windowSize: 1000
        )
        var messages: [ChatMessage] = [
            .assistant(AssistantMessage(content: "thinking")),
        ]
        _ = phase.afterResponse(usage: TokenUsage(input: 700, output: 100), messages: &messages)

        #expect(messages.count == 2)
        guard case let .user(content) = messages[1] else {
            Issue.record("Expected a single synthetic user message")
            return
        }
        #expect(content.contains("[Token usage:"))
        #expect(content.contains("Context budget advisory"))
    }
}

struct ContextBudgetPhasePruneTests {
    @Test func pruneSingleToolResult() throws {
        var messages: [ChatMessage] = [
            .user("query"),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "search", arguments: "{}")]
            )),
            .tool(id: "call_1", name: "search", content: "big result data here"),
        ]
        let args = try JSONEncoder().encode(PruneContextArguments(toolCallIds: ["call_1"]))
        let result = try executePruneContext(arguments: args, messages: &messages)

        #expect(result.toolResult.content == "Pruned 1 tool result(s).")
        #expect(result.historyWasRewritten)
        if case let .tool(_, _, content) = messages[2] {
            #expect(content == prunedToolResultContent)
        } else {
            Issue.record("Expected tool message at index 2")
        }
    }

    @Test func pruneMultipleToolResults() throws {
        var messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "data 1"),
            .tool(id: "call_2", name: "search", content: "data 2"),
            .tool(id: "call_3", name: "search", content: "data 3"),
        ]
        let args = try JSONEncoder().encode(PruneContextArguments(toolCallIds: ["call_1", "call_3"]))
        let result = try executePruneContext(arguments: args, messages: &messages)

        #expect(result.toolResult.content == "Pruned 2 tool result(s).")
        #expect(result.historyWasRewritten)
        if case let .tool(_, _, content) = messages[0] {
            #expect(content == prunedToolResultContent)
        } else { Issue.record("Expected tool message at index 0") }
        if case let .tool(_, _, content) = messages[1] {
            #expect(content == "data 2")
        } else { Issue.record("Expected tool message at index 1") }
        if case let .tool(_, _, content) = messages[2] {
            #expect(content == prunedToolResultContent)
        } else { Issue.record("Expected tool message at index 2") }
    }

    @Test func pruneUnknownIdSkippedSilently() throws {
        var messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "data"),
        ]
        let args = try JSONEncoder().encode(PruneContextArguments(toolCallIds: ["nonexistent"]))
        let result = try executePruneContext(arguments: args, messages: &messages)

        #expect(result.toolResult.content == "Pruned 0 tool result(s).")
        #expect(!result.historyWasRewritten)
        if case let .tool(_, _, content) = messages[0] { #expect(content == "data") }
    }

    @Test func pruneAlreadyPrunedIsIdempotent() throws {
        var messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: prunedToolResultContent),
        ]
        let args = try JSONEncoder().encode(PruneContextArguments(toolCallIds: ["call_1"]))
        let result = try executePruneContext(arguments: args, messages: &messages)

        #expect(result.toolResult.content == "Pruned 0 tool result(s).")
        #expect(!result.historyWasRewritten)
    }

    @Test func pruneEmptyArrayIsNoOp() throws {
        var messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "data"),
        ]
        let args = try JSONEncoder().encode(PruneContextArguments(toolCallIds: []))
        let result = try executePruneContext(arguments: args, messages: &messages)

        #expect(result.toolResult.content == "Pruned 0 tool result(s).")
        #expect(!result.historyWasRewritten)
    }

    @Test func prunePreservesMessageArrayCount() throws {
        var messages: [ChatMessage] = [
            .user("query"),
            .assistant(AssistantMessage(content: "")),
            .tool(id: "call_1", name: "search", content: "data"),
        ]
        let originalCount = messages.count
        let args = try JSONEncoder().encode(PruneContextArguments(toolCallIds: ["call_1"]))
        _ = try executePruneContext(arguments: args, messages: &messages)

        #expect(messages.count == originalCount)
    }

    @Test func pruneNonToolMessagesUntouched() throws {
        var messages: [ChatMessage] = [
            .system("system prompt"),
            .user("query"),
            .assistant(AssistantMessage(content: "thinking")),
            .tool(id: "call_1", name: "search", content: "data"),
        ]
        let args = try JSONEncoder().encode(PruneContextArguments(toolCallIds: ["call_1"]))
        _ = try executePruneContext(arguments: args, messages: &messages)

        if case let .system(content) = messages[0] {
            #expect(content == "system prompt")
        } else { Issue.record("Expected system message at index 0") }
        if case let .user(content) = messages[1] {
            #expect(content == "query")
        } else { Issue.record("Expected user message at index 1") }
        if case let .assistant(msg) = messages[2] {
            #expect(msg.content == "thinking")
        } else { Issue.record("Expected assistant message at index 2") }
    }
}

struct ContextBudgetPhaseBudgetComputationTests {
    @Test func budgetComputedFromInputPlusOutput() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(),
            windowSize: 10000
        )
        var messages: [ChatMessage] = []
        let result = phase.afterResponse(usage: TokenUsage(input: 3000, output: 500), messages: &messages)

        #expect(result.budget.currentUsage == 3500)
        #expect(result.budget.windowSize == 10000)
    }

    @Test func budgetExcludesReasoningTokens() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(),
            windowSize: 10000
        )
        var messages: [ChatMessage] = []
        let result = phase.afterResponse(
            usage: TokenUsage(input: 3000, output: 500, reasoning: 2000),
            messages: &messages
        )

        #expect(result.budget.currentUsage == 3500)
    }

    @Test func budgetSaturatesOnOverflow() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(),
            windowSize: Int.max
        )
        var messages: [ChatMessage] = []
        let result = phase.afterResponse(
            usage: TokenUsage(input: Int.max, output: 1),
            messages: &messages
        )

        #expect(result.budget.currentUsage == Int.max)
        #expect(result.budget.utilization == 1.0)
    }
}
