@testable import AgentRunKit
import Foundation
import Testing

private struct DraftAwareCompletionTool: AnyTool {
    typealias Context = ReportContext

    let name = "finalize"
    let description = "Return the final report. Call it alone once the work is done."
    let parametersSchema: JSONSchema = .object(properties: ["summary": .string()], required: ["summary"])

    func execute(arguments: Data, context: ReportContext) async throws -> ToolResult {
        let params = try JSONDecoder().decode(FinalizeParams.self, from: arguments)
        guard params.summary != "draft" else {
            return .error("The draft is not final yet.")
        }
        return .success("\(context.documentID):\(params.summary)")
    }
}

private func finalizeCall(id: String = "call_finalize", summary: String) -> ToolCall {
    ToolCall(id: id, name: "finalize", arguments: #"{"summary": "\#(summary)"}"#)
}

private let lookupCall = ToolCall(id: "call_lookup", name: "lookup", arguments: #"{"query": "spec"}"#)

private let reservedFinishCall = ToolCall(
    id: "call_finish", name: "finish", arguments: #"{"content": "done"}"#
)

struct CustomCompletionRunTests {
    @Test
    func theCompletionResultIsTheExactRunResult() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(
                content: "",
                toolCalls: [finalizeCall(summary: "all done")],
                tokenUsage: TokenUsage(input: 12, output: 4)
            )
        ])
        let agent = Agent<ReportContext>(client: client, tools: [], completionTool: finalize)

        let result = try await agent.run(userMessage: "Summarize", context: ReportContext(documentID: "doc-1"))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(try requireContent(result) == expected)
        #expect(result.finishReason == .completed)
        #expect(result.iterations == 1)
        #expect(result.totalTokenUsage == TokenUsage(input: 12, output: 4))
        #expect(await invocations.value == 1)

        #expect(result.history.count == 3)
        guard case let .assistant(assistant) = result.history[1] else {
            Issue.record("Expected the completion call to survive in history")
            return
        }
        #expect(assistant.toolCalls.map(\.name) == ["finalize"])
        guard case let .tool(id, name, content) = result.history[2] else {
            Issue.record("Expected the exact completion result as the final history entry")
            return
        }
        #expect(id == "call_finalize")
        #expect(name == "finalize")
        #expect(content == expected)
    }

    @Test
    func theChatMessageEntryPointCompletesThroughTheSameTool() async throws {
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finalizeCall(summary: "all done")])
        ])
        let agent = Agent<ReportContext>(client: client, tools: [], completionTool: finalize)

        let result = try await agent.run(
            userMessage: .user("Summarize"), context: ReportContext(documentID: "doc-1")
        )

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(try requireContent(result) == expected)
        #expect(result.finishReason == .completed)
    }

    @Test
    func approvalIsResolvedBeforeTheCompletionToolExecutes() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finalizeCall(summary: "ready")])
        ])
        let agent = Agent<ReportContext>(
            client: client, tools: [], completionTool: finalize,
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let approvals = CountingApprovalHandler()

        let result = try await agent.run(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1"),
            approvalHandler: approvals.handler
        )

        let expected = try encodedReport(documentID: "doc-1", summary: "ready")
        #expect(try requireContent(result) == expected)
        #expect(await invocations.value == 1)
        let requests = await approvals.requests
        #expect(requests.count == 1)
        #expect(requests.first?.toolName == "finalize")
        #expect(requests.first?.arguments == #"{"summary": "ready"}"#)
    }

    @Test
    func aDeniedCompletionFeedsTheDenialBackAndConsumesIterations() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_1", summary: "first")]),
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_2", summary: "second")])
        ])
        let agent = Agent<ReportContext>(
            client: client, tools: [], completionTool: finalize,
            configuration: AgentConfiguration(maxIterations: 2, approvalPolicy: .allTools)
        )
        let approvals = CountingApprovalHandler(decisions: ["finalize": .deny(reason: "Needs review")])

        let result = try await agent.run(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1"),
            approvalHandler: approvals.handler
        )

        #expect(result.finishReason == .maxIterationsReached(limit: 2))
        #expect(result.content == nil)
        #expect(await invocations.value == 0)
        #expect(await approvals.requestCount == 2)
        #expect(toolMessageContents(result.history) == ["Needs review", "Needs review"])
    }

    @Test
    func aThrowingCompletionToolFeedsItsFailureBackAndSucceedsOnTheNextTurn() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            guard params.summary != "draft" else { throw CustomCompletionTestError.draftRejected }
            return report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_1", summary: "draft")]),
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_2", summary: "final")])
        ])
        let agent = Agent<ReportContext>(client: client, tools: [], completionTool: finalize)

        let result = try await agent.run(userMessage: "Summarize", context: ReportContext(documentID: "doc-1"))

        let expected = try encodedReport(documentID: "doc-1", summary: "final")
        #expect(try requireContent(result) == expected)
        #expect(result.iterations == 2)
        #expect(await invocations.value == 2)
        let toolContents = toolMessageContents(result.history)
        #expect(toolContents.count == 2)
        #expect(toolContents.first?.contains("Tool 'finalize' failed") == true)
        #expect(toolContents.last == expected)
    }

    @Test
    func undecodableCompletionArgumentsBecomeRetryableFeedback() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_finalize_1", name: "finalize", arguments: #"{"summary": 7}"#)
            ]),
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_2", summary: "all done")])
        ])
        let agent = Agent<ReportContext>(client: client, tools: [], completionTool: finalize)

        let result = try await agent.run(userMessage: "Summarize", context: ReportContext(documentID: "doc-1"))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(try requireContent(result) == expected)
        #expect(result.iterations == 2)
        #expect(await invocations.value == 1)
        let toolContents = toolMessageContents(result.history)
        #expect(toolContents.first?.contains("Invalid arguments for 'finalize'") == true)
        #expect(toolContents.last == expected)
    }

    @Test
    func aCompletionToolErrorResultIsRetryableFeedback() async throws {
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_1", summary: "draft")]),
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_2", summary: "final")])
        ])
        let agent = Agent<ReportContext>(
            client: client, tools: [], completionTool: DraftAwareCompletionTool()
        )

        let result = try await agent.run(userMessage: "Summarize", context: ReportContext(documentID: "doc-1"))

        #expect(try requireContent(result) == "doc-1:final")
        #expect(result.iterations == 2)
        #expect(toolMessageContents(result.history) == ["The draft is not final yet.", "doc-1:final"])
    }

    @Test
    func aTimedOutCompletionToolFeedsBackAndTheRunContinues() async throws {
        let finalize = try makeFinalizeTool { params, context in
            if params.summary == "slow" {
                try await Task.sleep(for: .seconds(10))
            }
            return report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_1", summary: "slow")]),
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_2", summary: "quick")])
        ])
        let agent = Agent<ReportContext>(
            client: client, tools: [], completionTool: finalize,
            configuration: AgentConfiguration(toolTimeout: .milliseconds(50))
        )

        let result = try await agent.run(userMessage: "Summarize", context: ReportContext(documentID: "doc-1"))

        #expect(try requireContent(result) == encodedReport(documentID: "doc-1", summary: "quick"))
        let toolContents = toolMessageContents(result.history)
        #expect(toolContents.first?.contains("timed out") == true)
    }

    @Test
    func aSuccessfulCompletionAdvancesBudgetStateWithoutMutatingItsExactResult() async throws {
        let lookup = try makeLookupTool { _, _ in LookupOutput(matches: 3) }
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let client = StreamingMockLLMClient(
            generateResponses: [
                AssistantMessage(content: "", toolCalls: [lookupCall], tokenUsage: TokenUsage(input: 80, output: 10)),
                AssistantMessage(
                    content: "",
                    toolCalls: [finalizeCall(summary: "all done")],
                    tokenUsage: TokenUsage(input: 85, output: 10)
                )
            ],
            contextWindowSize: 100
        )
        let agent = Agent<ReportContext>(
            client: client, tools: [lookup], completionTool: finalize,
            configuration: AgentConfiguration(
                contextBudget: ContextBudgetConfig(softThreshold: 0.1, enableVisibility: true)
            )
        )

        let result = try await agent.run(userMessage: "Summarize", context: ReportContext(documentID: "doc-1"))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(try requireContent(result) == expected)
        #expect(result.history.count == 6)

        guard case let .tool(_, _, annotated) = result.history[2] else {
            Issue.record("Expected the ordinary tool result to carry the visibility annotation")
            return
        }
        #expect(annotated.hasPrefix(#"{"matches":3}"#))
        #expect(annotated.count > #"{"matches":3}"#.count)
        guard case .user = result.history[3] else {
            Issue.record("Expected the budget advisory to be delivered as a user turn")
            return
        }
        guard case let .tool(_, _, terminal) = result.history[5] else {
            Issue.record("Expected the exact completion result as the final history entry")
            return
        }
        #expect(terminal == expected)
    }
}

struct CustomCompletionRequestBoundaryTests {
    @Test
    func customModeAdvertisesTheCallersToolsWithoutTheBuiltInFinishTool() async throws {
        let lookup = try makeLookupTool { _, _ in LookupOutput(matches: 1) }
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finalizeCall(summary: "all done")])
        ])
        let agent = Agent<ReportContext>(client: client, tools: [lookup], completionTool: finalize)

        _ = try await agent.run(userMessage: "Summarize", context: ReportContext(documentID: "doc-1"))

        let definitions = try #require(await client.allCapturedTools.first)
        #expect(definitions == [ToolDefinition(lookup), ToolDefinition(finalize)])
    }

    @Test
    func customModeAdvertisesPruneContextWhenItIsEnabled() async throws {
        let lookup = try makeLookupTool { _, _ in LookupOutput(matches: 1) }
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finalizeCall(summary: "all done")])
        ])
        let agent = Agent<ReportContext>(
            client: client, tools: [lookup], completionTool: finalize,
            configuration: AgentConfiguration(contextBudget: ContextBudgetConfig(enablePruneTool: true))
        )

        _ = try await agent.run(userMessage: "Summarize", context: ReportContext(documentID: "doc-1"))

        let definitions = try #require(await client.allCapturedTools.first)
        #expect(definitions == [
            ToolDefinition(lookup), ToolDefinition(finalize), reservedPruneContextToolDefinition
        ])
    }

    @Test
    func defaultAgentsStillAdvertiseTheBuiltInFinishTool() async throws {
        let lookup = try makeLookupTool { _, _ in LookupOutput(matches: 1) }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [reservedFinishCall])
        ])
        let agent = Agent<ReportContext>(client: client, tools: [lookup])

        _ = try await agent.run(userMessage: "Summarize", context: ReportContext(documentID: "doc-1"))

        let definitions = try #require(await client.allCapturedTools.first)
        #expect(definitions == [ToolDefinition(lookup), reservedFinishToolDefinition])
    }
}

struct CustomCompletionExclusivityTests {
    @Test
    func synthesizedExclusivityFeedbackMarksEveryCallAsAnError() {
        let calls = [
            ToolCall(id: "call_lookup", name: "lookup", arguments: "{}"),
            ToolCall(id: "call_finalize_1", name: "finalize", arguments: "{}")
        ]
        let results = exclusivityFeedbackResults(for: calls, toolName: "finalize")
        #expect(results.count == 2)
        for entry in results {
            #expect(entry.result.isError)
        }
    }

    @Test
    func aCompletionCallBesideAnotherToolExecutesNothingAndRecoversOnTheNextTurn() async throws {
        let lookupInvocations = ToolInvocationCounter()
        let completionInvocations = ToolInvocationCounter()
        let lookup = try makeLookupTool { _, _ in
            await lookupInvocations.increment()
            return LookupOutput(matches: 1)
        }
        let finalize = try makeFinalizeTool { params, context in
            await completionInvocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                lookupCall, finalizeCall(id: "call_finalize_1", summary: "early")
            ]),
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_2", summary: "all done")])
        ])
        let agent = Agent<ReportContext>(client: client, tools: [lookup], completionTool: finalize)

        let result = try await agent.run(userMessage: "Go", context: ReportContext(documentID: "doc-1"))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(try requireContent(result) == expected)
        #expect(result.iterations == 2)
        #expect(await lookupInvocations.value == 0)
        #expect(await completionInvocations.value == 1)

        #expect(result.history.count == 6)
        guard case let .tool(lookupID, lookupName, lookupFeedback) = result.history[2],
              case let .tool(completionID, completionName, completionFeedback) = result.history[3]
        else {
            Issue.record("Expected one synthesized result per call in the violating batch")
            return
        }
        #expect([lookupID, completionID] == ["call_lookup", "call_finalize_1"])
        #expect([lookupName, completionName] == ["lookup", "finalize"])
        #expect(lookupFeedback == completionFeedback)
    }

    @Test
    func aRepeatedCompletionCallIsAnExclusivityViolation() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                finalizeCall(id: "call_finalize_1", summary: "one"),
                finalizeCall(id: "call_finalize_2", summary: "two")
            ]),
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_3", summary: "all done")])
        ])
        let agent = Agent<ReportContext>(client: client, tools: [], completionTool: finalize)

        let result = try await agent.run(userMessage: "Go", context: ReportContext(documentID: "doc-1"))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(try requireContent(result) == expected)
        #expect(await invocations.value == 1)
        #expect(toolMessageContents(result.history).count == 3)
    }

    @Test
    func pruneContextInsideAViolatingBatchIsNotExecuted() async throws {
        let lookup = try makeLookupTool { _, _ in LookupOutput(matches: 7) }
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [lookupCall]),
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_prune", name: "prune_context", arguments: #"{"tool_call_ids":["call_lookup"]}"#),
                finalizeCall(id: "call_finalize_1", summary: "early")
            ]),
            AssistantMessage(content: "", toolCalls: [finalizeCall(id: "call_finalize_2", summary: "all done")])
        ])
        let agent = Agent<ReportContext>(
            client: client, tools: [lookup], completionTool: finalize,
            configuration: AgentConfiguration(contextBudget: ContextBudgetConfig(enablePruneTool: true))
        )

        let result = try await agent.run(userMessage: "Go", context: ReportContext(documentID: "doc-1"))

        #expect(result.finishReason == .completed)
        #expect(toolMessageContents(result.history).first == #"{"matches":7}"#)
    }

    @Test
    func aLoneHallucinatedFinishCallBecomesUnknownToolFeedback() async throws {
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [reservedFinishCall]),
            AssistantMessage(content: "", toolCalls: [finalizeCall(summary: "all done")])
        ])
        let agent = Agent<ReportContext>(client: client, tools: [], completionTool: finalize)

        let result = try await agent.run(userMessage: "Go", context: ReportContext(documentID: "doc-1"))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(try requireContent(result) == expected)
        #expect(toolMessageContents(result.history) == [
            AgentError.toolNotFound(name: "finish").feedbackMessage, expected
        ])
    }

    @Test
    func theReservedFinishToolBesideAnotherCallStillThrows() async throws {
        let lookupInvocations = ToolInvocationCounter()
        let completionInvocations = ToolInvocationCounter()
        let lookup = try makeLookupTool { _, _ in
            await lookupInvocations.increment()
            return LookupOutput(matches: 1)
        }
        let finalize = try makeFinalizeTool { params, context in
            await completionInvocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [lookupCall, reservedFinishCall])
        ])
        let agent = Agent<ReportContext>(client: client, tools: [lookup], completionTool: finalize)

        await #expect(throws: AgentError.malformedHistory(.finishMustBeExclusive)) {
            try await agent.run(userMessage: "Go", context: ReportContext(documentID: "doc-1"))
        }
        #expect(await lookupInvocations.value == 0)
        #expect(await completionInvocations.value == 0)
    }
}
