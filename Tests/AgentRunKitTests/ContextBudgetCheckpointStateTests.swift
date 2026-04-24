@testable import AgentRunKit
import Foundation
import Testing

struct ContextBudgetCheckpointStateTests {
    @Test
    func phaseCheckpointStatePreservesAllFields() {
        let config = ContextBudgetConfig(softThreshold: 0.5)
        var phase = ContextBudgetPhase(config: config, windowSize: 1000)
        var messages: [ChatMessage] = []
        _ = phase.afterResponse(usage: TokenUsage(input: 600, output: 50), messages: &messages)
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
        _ = phase.afterResponse(usage: TokenUsage(input: 600, output: 50), messages: &messages)
        let snapshot = phase.checkpointState
        #expect(snapshot.softAdvisoryArmed == false)

        var restored = ContextBudgetPhase(checkpointState: snapshot)
        let result = restored.afterResponse(usage: TokenUsage(input: 700, output: 50), messages: &messages)
        #expect(result.advisoryEmitted == false)
    }
}
