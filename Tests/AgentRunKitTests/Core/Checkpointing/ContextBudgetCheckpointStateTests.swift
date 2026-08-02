@testable import AgentRunKit
import Foundation
import Testing

struct ContextBudgetCheckpointStateTests {
    @Test
    func phaseCheckpointStatePreservesAllFields() {
        let config = ContextBudgetConfig(softThreshold: 0.5)
        var phase = ContextBudgetPhase(config: config, windowSize: 1000)
        var messages: [ChatMessage] = []
        let update = phase.advanceAfterResponse(usage: TokenUsage(input: 600, output: 50))
        _ = phase.applyContinuationEffects(update, messages: &messages)
        let snapshot = phase.checkpointState
        #expect(snapshot.config == config)
        #expect(snapshot.windowSize == 1000)
        #expect(snapshot.lastBudget?.currentUsage == 650)
        #expect(snapshot.softAdvisoryArmed == false)
    }

    @Test
    func phaseCheckpointStatePreservesSoftAdvisoryArmed() {
        var phase = ContextBudgetPhase(
            config: ContextBudgetConfig(softThreshold: 0.5),
            windowSize: 1000
        )
        var messages: [ChatMessage] = []
        let update = phase.advanceAfterResponse(usage: TokenUsage(input: 600, output: 50))
        _ = phase.applyContinuationEffects(update, messages: &messages)
        let snapshot = phase.checkpointState
        #expect(snapshot.softAdvisoryArmed == false)

        var restored = ContextBudgetPhase(checkpointState: snapshot)
        let restoredUpdate = restored.advanceAfterResponse(usage: TokenUsage(input: 700, output: 50))
        #expect(restoredUpdate.advisoryDue == false)
        #expect(restored.applyContinuationEffects(restoredUpdate, messages: &messages) == false)
    }
}
