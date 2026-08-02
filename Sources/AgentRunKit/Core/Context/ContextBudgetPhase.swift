import Foundation

struct ContextBudgetUpdate {
    let budget: ContextBudget
    let advisoryDue: Bool
}

struct ContextBudgetPhase {
    let config: ContextBudgetConfig
    let windowSize: Int
    private(set) var lastBudget: ContextBudget?
    private var softAdvisoryArmed = true

    init(config: ContextBudgetConfig, windowSize: Int) {
        self.config = config
        self.windowSize = windowSize
    }

    init(checkpointState: ContextBudgetCheckpointState) {
        config = checkpointState.config
        windowSize = checkpointState.windowSize
        lastBudget = checkpointState.lastBudget
        softAdvisoryArmed = checkpointState.softAdvisoryArmed
    }

    var checkpointState: ContextBudgetCheckpointState {
        ContextBudgetCheckpointState(
            config: config,
            windowSize: windowSize,
            lastBudget: lastBudget,
            softAdvisoryArmed: softAdvisoryArmed
        )
    }

    mutating func advanceAfterResponse(usage: TokenUsage) -> ContextBudgetUpdate {
        let budget = ContextBudget(
            windowSize: windowSize,
            currentUsage: usage.inputOutputTotal,
            softThreshold: config.softThreshold
        )

        if let previous = lastBudget, previous.isAboveSoftThreshold, !budget.isAboveSoftThreshold {
            softAdvisoryArmed = true
        }

        lastBudget = budget
        return ContextBudgetUpdate(
            budget: budget,
            advisoryDue: budget.isAboveSoftThreshold && softAdvisoryArmed
        )
    }

    mutating func applyContinuationEffects(
        _ update: ContextBudgetUpdate,
        messages: inout [ChatMessage]
    ) -> Bool {
        let visibilityInsertedAsUser: Bool
        if config.enableVisibility {
            let annotation = update.budget.formatted(config.visibilityFormat)
            visibilityInsertedAsUser = injectVisibility(annotation, into: &messages)
        } else {
            visibilityInsertedAsUser = false
        }

        guard update.advisoryDue else { return false }
        softAdvisoryArmed = false
        let pct = Int(update.budget.utilization * 100)
        let pruneHint = config.enablePruneTool
            ? " Consider pruning irrelevant tool results with prune_context to free capacity, or provide"
            : " Provide"
        let advisory = "[Context budget advisory: usage is at \(pct)%.\(pruneHint) your final answer.]"
        if visibilityInsertedAsUser,
           let lastIndex = messages.indices.last,
           case let .user(content) = messages[lastIndex] {
            messages[lastIndex] = .user(content + "\n\n" + advisory)
        } else {
            messages.append(.user(advisory))
        }
        return true
    }
}

private extension ContextBudgetPhase {
    func injectVisibility(_ annotation: String, into messages: inout [ChatMessage]) -> Bool {
        guard let lastMessage = messages.last,
              case let .tool(id, name, content) = lastMessage
        else {
            messages.append(.user(annotation))
            return true
        }
        messages[messages.index(before: messages.endIndex)] = .tool(
            id: id,
            name: name,
            content: content + "\n\n" + annotation
        )
        return false
    }
}
