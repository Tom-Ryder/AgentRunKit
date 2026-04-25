@testable import AgentRunKit
import Foundation
import Testing

struct ContextBudgetUtilizationTests {
    @Test func utilizationAtZero() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 0)
        #expect(budget.utilization == 0.0)
    }

    @Test func utilizationAtFiftyPercent() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 500)
        #expect(budget.utilization == 0.5)
    }

    @Test func utilizationAtOneHundredPercent() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 1000)
        #expect(budget.utilization == 1.0)
    }

    @Test func utilizationClampedAboveOneHundredPercent() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 1500)
        #expect(budget.utilization == 1.0)
    }

    @Test func utilizationWithWindowSizeOne() {
        let zero = ContextBudget(windowSize: 1, currentUsage: 0)
        #expect(zero.utilization == 0.0)

        let full = ContextBudget(windowSize: 1, currentUsage: 1)
        #expect(full.utilization == 1.0)
    }
}

struct ContextBudgetRemainingTests {
    @Test func remainingNormal() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 300)
        #expect(budget.remaining == 700)
    }

    @Test func remainingAtZero() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 1000)
        #expect(budget.remaining == 0)
    }

    @Test func remainingClampedOnOverflow() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 1500)
        #expect(budget.remaining == 0)
    }
}

struct ContextBudgetThresholdTests {
    @Test func softThresholdBelowReturnsFalse() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 740, softThreshold: 0.75)
        #expect(!budget.isAboveSoftThreshold)
    }

    @Test func softThresholdAtBoundaryReturnsTrue() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 750, softThreshold: 0.75)
        #expect(budget.isAboveSoftThreshold)
    }

    @Test func softThresholdAboveReturnsTrue() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 800, softThreshold: 0.75)
        #expect(budget.isAboveSoftThreshold)
    }

    @Test func softThresholdNilReturnsFalse() {
        let budget = ContextBudget(windowSize: 1000, currentUsage: 999)
        #expect(!budget.isAboveSoftThreshold)
    }
}

struct ContextBudgetFormattingTests {
    @Test func standardFormatWithGroupingSeparators() {
        let budget = ContextBudget(windowSize: 32768, currentUsage: 14203)
        let formatted = budget.formatted(.standard)
        #expect(formatted == "[Token usage: 14,203 / 32,768]")
    }

    @Test func standardFormatSmallNumbers() {
        let budget = ContextBudget(windowSize: 100, currentUsage: 50)
        let formatted = budget.formatted(.standard)
        #expect(formatted == "[Token usage: 50 / 100]")
    }

    @Test func customTemplateFormat() {
        let budget = ContextBudget(windowSize: 10000, currentUsage: 5000)
        let formatted = budget.formatted(.custom("Budget: {usage}/{window} tokens"))
        #expect(formatted == "Budget: 5,000/10,000 tokens")
    }
}

struct ContextBudgetConfigTests {
    @Test func defaultConfig() {
        let config = ContextBudgetConfig()
        #expect(config.softThreshold == nil)
        #expect(config.enablePruneTool == false)
        #expect(config.enableVisibility == false)
        #expect(config.visibilityFormat == .standard)
    }

    @Test func configWithAllOptions() {
        let config = ContextBudgetConfig(
            softThreshold: 0.75,
            enablePruneTool: true,
            enableVisibility: true,
            visibilityFormat: .custom("{usage} of {window}")
        )
        #expect(config.softThreshold == 0.75)
        #expect(config.enablePruneTool)
        #expect(config.enableVisibility)
        #expect(config.visibilityFormat == .custom("{usage} of {window}"))
    }

    @Test func configSingleSoftThreshold() {
        let config = ContextBudgetConfig(softThreshold: 0.5)
        #expect(config.softThreshold == 0.5)
    }

    @Test func configEqualityDistinguishesByField() {
        let base = ContextBudgetConfig(softThreshold: 0.75, enablePruneTool: true, enableVisibility: true)
        let differentThreshold = ContextBudgetConfig(softThreshold: 0.8, enablePruneTool: true, enableVisibility: true)
        let differentPrune = ContextBudgetConfig(softThreshold: 0.75, enablePruneTool: false, enableVisibility: true)
        let identical = ContextBudgetConfig(softThreshold: 0.75, enablePruneTool: true, enableVisibility: true)
        #expect(base == identical)
        #expect(base != differentThreshold)
        #expect(base != differentPrune)
    }
}

struct PruneContextArgumentsTests {
    @Test func codingKeysRoundTrip() throws {
        let args = PruneContextArguments(toolCallIds: ["call_abc", "call_def"])
        let data = try JSONEncoder().encode(args)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"{"tool_call_ids":["call_abc","call_def"]}"#)

        let decoded = try JSONDecoder().decode(PruneContextArguments.self, from: data)
        #expect(decoded.toolCallIds == ["call_abc", "call_def"])
    }

    @Test func emptyToolCallIds() throws {
        let args = PruneContextArguments(toolCallIds: [])
        let data = try JSONEncoder().encode(args)
        let decoded = try JSONDecoder().decode(PruneContextArguments.self, from: data)
        #expect(decoded.toolCallIds.isEmpty)
    }
}
