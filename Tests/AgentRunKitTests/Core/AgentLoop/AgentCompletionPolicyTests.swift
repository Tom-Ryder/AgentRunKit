@testable import AgentRunKit
import Testing

private let finishCall = ToolCall(id: "call_finish", name: "finish", arguments: #"{"content": "done"}"#)
private let searchCall = ToolCall(id: "call_search", name: "search", arguments: "{}")
private let pruneCall = ToolCall(id: "call_prune", name: "prune_context", arguments: #"{"tool_call_ids": []}"#)
private let finalizeCall = ToolCall(id: "call_finalize", name: "finalize", arguments: "{}")

struct BuiltInFinishClassificationTests {
    private let policy = AgentCompletionPolicy.builtInFinish

    @Test
    func exclusiveFinishIsTheTerminalCall() throws {
        #expect(try policy.classify([finishCall]) == .builtInFinish(finishCall))
    }

    @Test
    func batchWithoutFinishHasNoTerminalCall() throws {
        #expect(try policy.classify([searchCall, pruneCall]) == TerminalCallDisposition.none)
        #expect(try policy.classify([]) == TerminalCallDisposition.none)
    }

    @Test
    func finishBesideAnotherCallThrows() {
        #expect(throws: AgentError.malformedHistory(.finishMustBeExclusive)) {
            try policy.classify([searchCall, finishCall])
        }
    }

    @Test
    func repeatedFinishThrows() {
        #expect(throws: AgentError.malformedHistory(.finishMustBeExclusive)) {
            try policy.classify([finishCall, finishCall])
        }
    }

    @Test
    func aToolNamedLikeACustomCompletionStaysOrdinary() throws {
        #expect(try policy.classify([finalizeCall]) == TerminalCallDisposition.none)
    }
}

struct ExecutableCompletionClassificationTests {
    private let policy = AgentCompletionPolicy.executableTool(name: "finalize")

    @Test
    func exclusiveCompletionCallIsTerminal() throws {
        #expect(try policy.classify([finalizeCall]) == .executableCompletion(finalizeCall))
    }

    @Test
    func completionBesideAnotherCallIsFeedbackCarryingTheWholeBatch() throws {
        #expect(
            try policy.classify([searchCall, finalizeCall]) == .exclusivityViolation([searchCall, finalizeCall])
        )
    }

    @Test
    func completionBesidePruneContextIsAViolation() throws {
        #expect(
            try policy.classify([pruneCall, finalizeCall]) == .exclusivityViolation([pruneCall, finalizeCall])
        )
    }

    @Test
    func repeatedCompletionIsAViolation() throws {
        #expect(
            try policy.classify([finalizeCall, finalizeCall]) == .exclusivityViolation([finalizeCall, finalizeCall])
        )
    }

    @Test
    func loneHallucinatedFinishFallsThroughToOrdinaryDispatch() throws {
        #expect(try policy.classify([finishCall]) == TerminalCallDisposition.none)
    }

    @Test
    func hallucinatedFinishBesideAnotherCallStillThrows() {
        #expect(throws: AgentError.malformedHistory(.finishMustBeExclusive)) {
            try policy.classify([finalizeCall, finishCall])
        }
    }

    @Test
    func ordinaryBatchHasNoTerminalCall() throws {
        #expect(try policy.classify([searchCall, pruneCall]) == TerminalCallDisposition.none)
    }
}

struct TerminalOutcomeIdentityTests {
    private let outcome = AgentTerminalOutcome(content: #"{"summary":"shipped"}"#, toolName: "finalize")

    @Test
    func theConfiguredCompletionToolOwnsItsOutcome() throws {
        try AgentCompletionPolicy.executableTool(name: "finalize").validateIdentity(of: outcome)
    }

    @Test
    func anotherCompletionToolCannotClaimTheOutcome() {
        #expect(
            throws: AgentCheckpointError.completionToolMismatch(checkpointed: "finalize", live: "publish")
        ) {
            try AgentCompletionPolicy.executableTool(name: "publish").validateIdentity(of: outcome)
        }
    }

    @Test
    func builtInFinishAgentsNeverOwnATerminalOutcome() {
        #expect(throws: AgentCheckpointError.completionToolMismatch(checkpointed: "finalize", live: nil)) {
            try AgentCompletionPolicy.builtInFinish.validateIdentity(of: outcome)
        }
    }
}
