import Foundation

struct AfterResponseResult {
    let budget: ContextBudget
    let advisoryEmitted: Bool
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

    @discardableResult
    mutating func afterResponse(usage: TokenUsage, messages: inout [ChatMessage]) -> AfterResponseResult {
        let budget = ContextBudget(
            windowSize: windowSize,
            currentUsage: usage.inputOutputTotal,
            softThreshold: config.softThreshold
        )

        if let previous = lastBudget, previous.isAboveSoftThreshold, !budget.isAboveSoftThreshold {
            softAdvisoryArmed = true
        }

        let visibilityInsertedAsUser: Bool
        if config.enableVisibility {
            let annotation = budget.formatted(config.visibilityFormat)
            visibilityInsertedAsUser = injectVisibility(annotation, into: &messages)
        } else {
            visibilityInsertedAsUser = false
        }

        var advisoryEmitted = false
        if budget.isAboveSoftThreshold, softAdvisoryArmed {
            softAdvisoryArmed = false
            advisoryEmitted = true
            let pct = Int(budget.utilization * 100)
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
        }

        lastBudget = budget
        return AfterResponseResult(budget: budget, advisoryEmitted: advisoryEmitted)
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
