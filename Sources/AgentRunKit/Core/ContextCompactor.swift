import Foundation

struct ContextCompactor {
    let client: any LLMClient
    let toolDefinitions: [ToolDefinition]
    let configuration: AgentConfiguration

    init(client: any LLMClient, toolDefinitions: [ToolDefinition], configuration: AgentConfiguration) {
        self.client = client
        self.toolDefinitions = toolDefinitions
        self.configuration = configuration
    }

    private static let minimumPruningReduction = 0.2
    private static let pruningPreviewLength = 80
    private static let maxConsecutiveSummarizationFailures = 3

    private var consecutiveSummarizationFailures = 0

    @discardableResult
    mutating func compactOrTruncateIfNeeded(
        _ messages: inout [ChatMessage],
        lastTotalTokens: Int?,
        totalUsage: inout TokenUsage
    ) async -> Bool {
        guard let totalTokens = lastTotalTokens,
              let windowSize = client.contextWindowSize,
              let threshold = configuration.compactionThreshold,
              Double(totalTokens) / Double(windowSize) >= threshold
        else {
            truncateIfNeeded(&messages)
            return false
        }

        let (pruned, reductionRatio) = pruneObservations(messages)
        if reductionRatio > Self.minimumPruningReduction {
            messages = pruned
            consecutiveSummarizationFailures = 0
            return true
        }

        guard consecutiveSummarizationFailures < Self.maxConsecutiveSummarizationFailures else {
            truncateIfNeeded(&messages)
            return false
        }

        do {
            let (compacted, compactionUsage) = try await summarize(pruned)
            messages = compacted
            totalUsage += compactionUsage
            consecutiveSummarizationFailures = 0
            return true
        } catch {
            consecutiveSummarizationFailures += 1
            truncateIfNeeded(&messages)
            return false
        }
    }

    func pruneObservations(_ messages: [ChatMessage]) -> (messages: [ChatMessage], reductionRatio: Double) {
        let lastAssistantIndex = messages.lastIndex { if case .assistant = $0 { true } else { false } }

        var originalChars = 0
        var prunedChars = 0
        var result: [ChatMessage] = []

        for (index, message) in messages.enumerated() {
            if case let .tool(id, name, content) = message,
               let boundary = lastAssistantIndex,
               index < boundary {
                originalChars += content.count
                if content == prunedToolResultContent {
                    prunedChars += content.count
                    result.append(message)
                    continue
                }
                let firstLine = content.prefix(Self.pruningPreviewLength)
                    .split(separator: "\n", maxSplits: 1).first
                    .map(String.init) ?? String(content.prefix(Self.pruningPreviewLength))
                let placeholder = "[Result from \(name): \(firstLine)... (pruned)]"
                prunedChars += placeholder.count
                result.append(.tool(id: id, name: name, content: placeholder))
            } else {
                if case let .tool(_, _, content) = message {
                    originalChars += content.count
                    prunedChars += content.count
                }
                result.append(message)
            }
        }

        let ratio: Double = originalChars > 0
            ? 1.0 - (Double(prunedChars) / Double(originalChars))
            : 0.0
        return (result, ratio)
    }

    func summarize(_ messages: [ChatMessage]) async throws -> (messages: [ChatMessage], usage: TokenUsage) {
        let taskContext = extractTaskContext(messages)
        let recentContext = extractRecentContext(messages)

        let prompt = configuration.compactionPrompt ?? Self.summarizationPrompt
        let summaryRequest = Self.stripMedia(messages) + [.user(prompt)]
        let response = try await client.generate(
            messages: summaryRequest, tools: toolDefinitions, responseFormat: nil, requestContext: nil
        )

        let compactionUsage = response.tokenUsage ?? TokenUsage()
        let bridge = Self.bridgeMessage(summary: response.content)
        let acknowledgment = AssistantMessage(content: "Understood. Resuming from the checkpoint.")

        var compacted = taskContext
        compacted.append(bridge)
        compacted.append(.assistant(acknowledgment))
        compacted.append(contentsOf: recentContext)

        return (compacted, compactionUsage)
    }

    static func truncateToolResult(_ content: String, configuration: AgentConfiguration) -> String {
        guard let max = configuration.maxToolResultCharacters,
              content.count > max else { return content }
        let marker = "\n\n...[truncated]...\n\n"
        let contentBudget = Swift.max(max - marker.count, 0)
        let headBudget = contentBudget * 3 / 5
        let tailBudget = contentBudget - headBudget
        return "\(content.prefix(headBudget))\(marker)\(content.suffix(tailBudget))"
    }

    private func truncateIfNeeded(_ messages: inout [ChatMessage]) {
        guard let maxMessages = configuration.maxMessages else { return }
        messages = messages.truncated(to: maxMessages, preservingSystemPrompt: true)
    }
}

private extension ContextCompactor {
    static func stripMedia(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            guard case let .userMultimodal(parts) = message else { return message }
            let stripped = parts.map { part -> ContentPart in
                switch part {
                case .text: return part
                case .imageURL, .imageBase64: return .text("[image]")
                case .videoBase64: return .text("[video]")
                case .pdfBase64: return .text("[PDF]")
                case .audioBase64: return .text("[audio]")
                }
            }
            return .userMultimodal(stripped)
        }
    }

    func extractTaskContext(_ messages: [ChatMessage]) -> [ChatMessage] {
        var context: [ChatMessage] = []
        for message in messages {
            if case .assistant = message { break }
            context.append(message)
        }
        return context
    }

    func extractRecentContext(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard let lastAssistantIndex = messages.lastIndex(where: {
            if case .assistant = $0 { true } else { false }
        }) else { return [] }

        let trailing = messages[lastAssistantIndex...]
        let hasToolResults = trailing.dropFirst().contains {
            if case .tool = $0 { true } else { false }
        }
        return hasToolResults ? Array(trailing) : []
    }

    static func bridgeMessage(summary: String) -> ChatMessage {
        .user("""
        [Context Continuation] Another instance of this model was working on this task \
        and produced the following checkpoint summary of progress so far:

        ---

        \(summary)

        ---

        Continue from where the previous work left off. The task, progress, current state, \
        and remaining work are described in the summary above. Pick up exactly where it stopped.
        """)
    }

    static var summarizationPrompt: String {
        """
        You are performing a CONTEXT CHECKPOINT. Create a detailed handoff summary that \
        another instance of yourself could use to seamlessly resume this task.

        Your summary must include:

        1. Task & Objective: What is the goal? What were the original instructions?

        2. Current Progress: What has been accomplished so far?
           - Key actions taken and their outcomes
           - Tools called and their significant results
           - Decisions made and their rationale

        3. Current State: What is the exact state right now?
           - What is working and verified?
           - What files or resources have been modified?
           - Any important data, values, or configurations

        4. Remaining Work: What still needs to be done?
           - Outstanding tasks in priority order
           - Known issues or blockers

        5. Critical Context: Anything essential that must not be lost
           - Constraints, preferences, or requirements from the user
           - Dependencies between components
           - Non-obvious gotchas discovered during the work

        Write as if briefing a colleague who will take over immediately. Be specific — include \
        file paths, function names, and concrete values rather than vague descriptions. \
        Do not use any tools.
        """
    }
}
