@testable import AgentRunKit
import Foundation
import Testing

struct ChatMessageHistoryValidationTests {
    @Test
    func resolvedToolBatchIsValid() throws {
        let call = ToolCall(id: "call_1", name: "lookup", arguments: "{}")
        let messages: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(content: "", toolCalls: [call])),
            .tool(id: "call_1", name: "lookup", content: "done"),
            .user("Next"),
        ]

        try messages.validateForLLMRequest()
    }

    @Test
    func unfinishedToolBatchThrows() throws {
        let messages: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
            )),
            .user("Next"),
        ]

        #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
            try messages.validateForLLMRequest()
        }
    }

    @Test
    func strayToolResultThrows() throws {
        let messages: [ChatMessage] = [
            .user("Hi"),
            .tool(id: "call_1", name: "lookup", content: "done"),
        ]

        #expect(throws: AgentError.malformedHistory(.unexpectedToolResult(id: "call_1"))) {
            try messages.validateForLLMRequest()
        }
    }

    @Test
    func outOfOrderToolResultThrows() throws {
        let messages: [ChatMessage] = [
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "first", arguments: "{}"),
                ToolCall(id: "call_2", name: "second", arguments: "{}"),
            ])),
            .tool(id: "call_2", name: "second", content: "two"),
            .tool(id: "call_1", name: "first", content: "one"),
        ]

        #expect(throws: AgentError.malformedHistory(
            .toolResultOrderMismatch(expectedID: "call_1", actualID: "call_2")
        )) {
            try messages.validateForLLMRequest()
        }
    }

    @Test
    func userDefinedFinishToolBatchIsValidForGenericRequests() throws {
        let messages: [ChatMessage] = [
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#),
                ToolCall(id: "call_1", name: "lookup", arguments: "{}"),
            ])),
            .tool(id: "finish_1", name: "finish", content: "done"),
            .tool(id: "call_1", name: "lookup", content: "details"),
        ]

        try messages.validateForLLMRequest()
    }
}

struct AgentMessageHistoryValidationTests {
    @Test
    func finishMustBeExclusiveForAgentHistory() throws {
        let messages: [ChatMessage] = [
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#),
                ToolCall(id: "call_1", name: "lookup", arguments: "{}"),
            ])),
        ]

        #expect(throws: AgentError.malformedHistory(.finishMustBeExclusive)) {
            try messages.validateForAgentHistory()
        }
    }
}

struct ChatMessageTerminalHistoryTests {
    @Test
    func terminalFinishOnlyAssistantIsRemoved() throws {
        let history: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#)]
            )),
        ]

        let sanitized = try history.sanitizedTerminalHistory()

        #expect(sanitized == [.user("Hi")])
    }

    @Test
    func terminalFinishStrippingKeepsAssistantContent() throws {
        let history: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(
                content: "Final answer",
                toolCalls: [ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#)]
            )),
        ]

        let sanitized = try history.sanitizedTerminalHistory()

        #expect(sanitized.count == 2)
        guard case let .assistant(message) = sanitized[1] else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(message.content == "Final answer")
        #expect(message.toolCalls.isEmpty)
        #expect(message.continuity == nil)
    }

    @Test
    func terminalFinishStrippingKeepsAssistantContinuity() throws {
        let history: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(
                content: "Final answer",
                toolCalls: [ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#)],
                continuity: AssistantContinuity(
                    substrate: .responses,
                    payload: .object([
                        "response_id": .string("resp_123"),
                    ])
                )
            )),
        ]

        let sanitized = try history.sanitizedTerminalHistory()

        #expect(sanitized.count == 2)
        guard case let .assistant(message) = sanitized[1] else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(message.content == "Final answer")
        #expect(message.toolCalls.isEmpty)
        #expect(message.continuity == AssistantContinuity(
            substrate: .responses,
            payload: .object([
                "response_id": .string("resp_123"),
            ])
        ))
    }

    @Test
    func terminalFinishStrippingKeepsReasoningOnlyAssistant() throws {
        let history: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#)],
                reasoning: ReasoningContent(content: "Reasoning only"),
                continuity: AssistantContinuity(
                    substrate: .anthropicMessages,
                    payload: .object([
                        "thinking": .string("Reasoning only"),
                        "signature": .string("sig_123"),
                    ])
                )
            )),
        ]

        let sanitized = try history.sanitizedTerminalHistory()

        #expect(sanitized.count == 2)
        guard case let .assistant(message) = sanitized[1] else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(message.content.isEmpty)
        #expect(message.toolCalls.isEmpty)
        #expect(message.reasoning == ReasoningContent(content: "Reasoning only"))
        #expect(message.continuity == AssistantContinuity(
            substrate: .anthropicMessages,
            payload: .object([
                "thinking": .string("Reasoning only"),
                "signature": .string("sig_123"),
            ])
        ))
    }

    @Test
    func terminalFinishStrippingKeepsReasoningDetailsOnlyAssistant() throws {
        let history: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#)],
                reasoningDetails: [
                    .object([
                        "type": .string("reasoning.encrypted"),
                        "encrypted": .string("blob=="),
                        "index": .int(0),
                    ])
                ],
                continuity: AssistantContinuity(
                    substrate: .responses,
                    payload: .object([
                        "response_id": .string("resp_123"),
                    ])
                )
            )),
        ]

        let sanitized = try history.sanitizedTerminalHistory()

        #expect(sanitized.count == 2)
        guard case let .assistant(message) = sanitized[1] else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(message.content.isEmpty)
        #expect(message.toolCalls.isEmpty)
        #expect(message.reasoning == nil)
        #expect(message.reasoningDetails == [
            .object([
                "type": .string("reasoning.encrypted"),
                "encrypted": .string("blob=="),
                "index": .int(0),
            ])
        ])
        #expect(message.continuity == AssistantContinuity(
            substrate: .responses,
            payload: .object([
                "response_id": .string("resp_123"),
            ])
        ))
    }

    @Test
    func terminalFinishOnlyAssistantIsRemovedEvenWithContinuity() throws {
        let history: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#)],
                continuity: AssistantContinuity(
                    substrate: .responses,
                    payload: .object([
                        "response_id": .string("resp_123"),
                    ])
                )
            )),
        ]

        let sanitized = try history.sanitizedTerminalHistory()

        #expect(sanitized == [.user("Hi")])
    }

    @Test
    func inheritanceDropsTrailingUnresolvedToolBatch() {
        let history: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
            )),
        ]

        #expect(history.resolvedPrefixForInheritance() == [.user("Hi")])
    }

    @Test
    func inheritancePreservesContinuityOnUntouchedAssistantTurns() {
        let continuity = AssistantContinuity(
            substrate: .responses,
            payload: .object([
                "response_id": .string("resp_123"),
            ])
        )
        let history: [ChatMessage] = [
            .user("Earlier"),
            .assistant(AssistantMessage(content: "Done", continuity: continuity)),
            .user("Continue"),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
            )),
        ]

        let inherited = history.resolvedPrefixForInheritance()

        #expect(inherited.count == 3)
        guard case let .assistant(message) = inherited[1] else {
            Issue.record("Expected assistant message in inherited prefix")
            return
        }
        #expect(message.content == "Done")
        #expect(message.continuity == continuity)
    }
}
