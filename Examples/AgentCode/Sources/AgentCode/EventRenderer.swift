import AgentRunKit
import Foundation

@MainActor
final class EventRenderer {
    private var activeTools: [String: ToolActivity] = [:]
    private var spinnerTask: Task<Void, Never>?
    private var spinnerIndex = 0
    private var hasActiveSpinnerLine = false

    func render(_ event: StreamEvent) {
        switch event.kind {
        case let .delta(text), let .reasoningDelta(text):
            clearSpinnerLineIfNeeded()
            Terminal.write(text, terminator: "")
        case let .toolCallStarted(name, id):
            startTool(name: name, id: id)
        case let .toolCallCompleted(id, name, result):
            completeTool(id: id, fallbackName: name, result: result)
        case let .toolApprovalRequested(request):
            pauseForApproval(toolCallId: request.toolCallId)
        case let .toolApprovalResolved(_, decision):
            Terminal.writeLine("\(Terminal.pill("approval", style: .yellow)) \(decision.displayName)")
        case let .finished(usage, content, reason, _):
            finishSpinner()
            renderFinished(usage: usage, content: content, reason: reason)
        case let .iterationCompleted(usage, iteration, _):
            renderIteration(usage: usage, iteration: iteration)
        case let .compacted(totalTokens, windowSize):
            clearSpinnerLineIfNeeded()
            Terminal.writeLine("\(Terminal.pill("context", style: .yellow)) compacted · \(totalTokens)/\(windowSize)")
        case let .budgetUpdated(budget):
            renderBudget(prefix: "Budget", budget: budget)
        case let .budgetAdvisory(budget):
            renderBudget(prefix: "Budget advisory", budget: budget)
        case let .subAgentStarted(toolCallId, toolName):
            startTool(name: "sub-agent \(toolName)", id: toolCallId)
        case let .subAgentEvent(_, toolName, childEvent):
            clearSpinnerLineIfNeeded()
            Terminal.write("\(Terminal.style("[\(toolName)]", .dim)) ", terminator: "")
            render(childEvent)
        case let .subAgentCompleted(toolCallId, toolName, result):
            completeTool(id: toolCallId, fallbackName: "sub-agent \(toolName)", result: result)
        case .audioData, .audioTranscript, .audioFinished:
            break
        }
    }

    func finishSpinner() {
        spinnerTask?.cancel()
        spinnerTask = nil
        clearSpinnerLineIfNeeded()
    }

    private func startTool(name: String, id: String) {
        activeTools[id] = ToolActivity(name: name, startedAt: Date())
        guard Terminal.isInteractiveOutput() else { return }
        if spinnerTask == nil {
            spinnerTask = Task { [weak self] in
                while !Task.isCancelled {
                    await MainActor.run {
                        self?.renderSpinnerFrame()
                    }
                    try? await Task.sleep(for: .milliseconds(90))
                }
            }
        }
    }

    private func completeTool(id: String, fallbackName: String, result: ToolResult) {
        let activity = activeTools.removeValue(forKey: id) ?? ToolActivity(name: fallbackName, startedAt: Date())
        clearSpinnerLineIfNeeded()
        Terminal.writeLine(completedLine(activity: activity, result: result))
        if result.isError {
            Terminal.rule("tool output", style: .red)
            Terminal.writeLine(result.content)
            Terminal.rule(style: .red)
        }
        if activeTools.isEmpty {
            finishSpinner()
        }
    }

    private func pauseForApproval(toolCallId: String) {
        spinnerTask?.cancel()
        spinnerTask = nil
        activeTools.removeValue(forKey: toolCallId)
        clearSpinnerLineIfNeeded()
    }

    private func renderSpinnerFrame() {
        guard Terminal.isInteractiveOutput() else { return }
        guard let activity = activeTools.values.min(by: { $0.startedAt < $1.startedAt }) else {
            finishSpinner()
            return
        }
        let frame = SpinnerFrame.frames[spinnerIndex % SpinnerFrame.frames.count]
        spinnerIndex += 1
        Terminal.clearLine()
        Terminal.write(
            "\(Terminal.style(frame, .cyan)) \(Terminal.style(activity.name, .bold)) \(activity.detail)",
            terminator: ""
        )
        hasActiveSpinnerLine = true
    }

    private func clearSpinnerLineIfNeeded() {
        guard hasActiveSpinnerLine else { return }
        Terminal.clearLine()
        hasActiveSpinnerLine = false
    }

    private func completedLine(activity: ToolActivity, result: ToolResult) -> String {
        let elapsed = max(0.0, Date().timeIntervalSince(activity.startedAt))
        let status = result.isError
            ? Terminal.pill("failed", style: .red)
            : Terminal.pill("done", style: .green)
        return "\(status) \(Terminal.style(activity.name, .bold)) \(activity.detail) " +
            Terminal.style(format(elapsed), .dim)
    }

    private func renderFinished(usage: TokenUsage, content: String?, reason: FinishReason?) {
        if let content, !content.isEmpty {
            Terminal.writeLine("")
            Terminal.writeLine(content)
        }
        Terminal.writeLine("")
        let status = reason?.description ?? "completed"
        Terminal.writeLine("\(Terminal.pill("finished", style: .green)) \(status) · \(usage.total) tokens")
    }

    private func renderIteration(usage: TokenUsage, iteration: Int) {
        if !Terminal.isInteractiveOutput() {
            Terminal.writeLine(Terminal.style("round \(iteration) · \(usage.total) tokens", .dim))
        }
    }

    private func renderBudget(prefix: String, budget: ContextBudget) {
        if !Terminal.isInteractiveOutput() {
            Terminal.writeLine(
                Terminal.style("\(prefix.lowercased()) · \(budget.currentUsage)/\(budget.windowSize)", .dim)
            )
        }
    }

    private func format(_ elapsed: TimeInterval) -> String {
        if elapsed < 1 {
            return String(format: "%.0fms", elapsed * 1000)
        }
        return String(format: "%.1fs", elapsed)
    }
}

private struct ToolActivity {
    let name: String
    let startedAt: Date

    var detail: String {
        ToolActivityFormatter.detail(for: name)
    }
}

private enum SpinnerFrame {
    static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
}

private enum ToolActivityFormatter {
    static func detail(for name: String) -> String {
        switch name {
        case "workspace_status":
            Terminal.style("detecting project", .dim)
        case "list_files":
            Terminal.style("scanning workspace", .dim)
        case "read_file":
            Terminal.style("reading file", .dim)
        case "grep":
            Terminal.style("searching source", .dim)
        case "glob":
            Terminal.style("matching files", .dim)
        case "git_diff":
            Terminal.style("checking changes", .dim)
        case "edit_file", "multi_edit", "write_file":
            Terminal.style("writing changes", .dim)
        case "run_command":
            Terminal.style("running verification", .dim)
        default:
            ""
        }
    }
}

private extension ToolApprovalDecision {
    var displayName: String {
        switch self {
        case .approve:
            "approved"
        case .approveAlways:
            "approved always"
        case .approveWithModifiedArguments:
            "approved with modified arguments"
        case .deny:
            "denied"
        }
    }
}

private extension FinishReason {
    var description: String {
        String(describing: self)
    }
}
