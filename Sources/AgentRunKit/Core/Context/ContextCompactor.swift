import Foundation

struct ContextCompactor {
    typealias SummaryGenerator = ([ChatMessage]) async throws -> AssistantMessage

    enum Outcome: Equatable {
        case unchanged
        case rewritten
        case compacted

        var didRewriteHistory: Bool {
            self != .unchanged
        }

        var emitsCompactionEvent: Bool {
            self == .compacted
        }
    }

    let client: any LLMClient
    let configuration: AgentConfiguration

    init(client: any LLMClient, configuration: AgentConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    private static let minimumPruningReduction = 0.2
    private static let pruningPreviewLength = 80
    private static let maxConsecutiveSummarizationFailures = 3
    private static let toolResultTruncationMarkers = [
        "\n\n...[truncated]...\n\n",
        "...[truncated]...",
        "[truncated]",
        "...",
    ]

    private var consecutiveSummarizationFailures = 0

    @discardableResult
    mutating func compactOrTruncateIfNeeded(
        _ messages: inout [ChatMessage],
        lastTotalTokens: Int?,
        totalUsage: inout TokenUsage,
        summaryGenerator: SummaryGenerator? = nil
    ) async throws -> Outcome {
        guard let totalTokens = lastTotalTokens,
              let windowSize = client.contextWindowSize,
              let threshold = configuration.compactionThreshold,
              Double(totalTokens) / Double(windowSize) >= threshold
        else {
            return truncateIfNeeded(&messages) ? .rewritten : .unchanged
        }

        let pruning = pruneObservations(messages)
        if pruning.messages != messages, pruning.reductionRatio > Self.minimumPruningReduction {
            messages = pruning.messages
            consecutiveSummarizationFailures = 0
            return .compacted
        }

        guard consecutiveSummarizationFailures < Self.maxConsecutiveSummarizationFailures else {
            return truncateIfNeeded(&messages) ? .rewritten : .unchanged
        }

        do {
            let response = try await summaryResponse(pruning.messages, summaryGenerator: summaryGenerator)
            let summary = try Self.validatedSummary(from: response)
            let compacted = compactedMessages(from: pruning.messages, summary: summary)
            let compactionUsage = response.tokenUsage ?? TokenUsage()
            messages = compacted
            totalUsage += compactionUsage
            consecutiveSummarizationFailures = 0
            return .compacted
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            consecutiveSummarizationFailures += 1
            return truncateIfNeeded(&messages) ? .rewritten : .unchanged
        }
    }

    @discardableResult
    mutating func reactiveCompact(
        _ messages: inout [ChatMessage],
        totalUsage: inout TokenUsage,
        summaryGenerator: SummaryGenerator? = nil
    ) async throws -> Outcome {
        var didRewriteHistory = truncateIfNeeded(&messages)
        if configuration.compactionThreshold != nil {
            let pruning = pruneObservations(messages)
            if pruning.messages != messages, pruning.reductionRatio > 0 {
                messages = pruning.messages
                didRewriteHistory = true
            }
        }
        if didRewriteHistory {
            return .rewritten
        }

        guard configuration.compactionThreshold != nil,
              consecutiveSummarizationFailures < Self.maxConsecutiveSummarizationFailures
        else {
            return .unchanged
        }

        do {
            let response = try await summaryResponse(messages, summaryGenerator: summaryGenerator)
            let summary = try Self.validatedSummary(from: response)
            let compacted = compactedMessages(from: messages, summary: summary)
            let compactionUsage = response.tokenUsage ?? TokenUsage()
            messages = compacted
            totalUsage += compactionUsage
            consecutiveSummarizationFailures = 0
            return .compacted
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            consecutiveSummarizationFailures += 1
            return .unchanged
        }
    }

    func pruneObservations(_ messages: [ChatMessage]) -> (messages: [ChatMessage], reductionRatio: Double) {
        let lastAssistantIndex = messages.lastIndex { if case .assistant = $0 { true } else { false } }

        var originalChars = 0
        var prunedChars = 0
        var firstRewriteIndex: Int?
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
                if placeholder != content, firstRewriteIndex == nil {
                    firstRewriteIndex = index
                }
            } else {
                if case let .tool(_, _, content) = message {
                    originalChars += content.count
                    prunedChars += content.count
                }
                result.append(message)
            }
        }

        if let firstRewriteIndex {
            result.stripResponsesContinuationAnchorsOnAssistants(after: firstRewriteIndex)
        }

        let ratio: Double = originalChars > 0
            ? 1.0 - (Double(prunedChars) / Double(originalChars))
            : 0.0
        return (result, ratio)
    }

    func summaryResponse(
        _ messages: [ChatMessage],
        summaryGenerator: SummaryGenerator?
    ) async throws -> AssistantMessage {
        let prompt = configuration.compactionPrompt ?? Self.summarizationPrompt
        let summaryRequest = Self.stripMedia(messages) + [.user(prompt)]
        if let summaryGenerator {
            return try await summaryGenerator(summaryRequest)
        }
        return try await client.generate(
            messages: summaryRequest,
            tools: [],
            responseFormat: nil,
            requestContext: nil
        )
    }

    func summarize(_ messages: [ChatMessage]) async throws -> (messages: [ChatMessage], usage: TokenUsage) {
        let response = try await summaryResponse(messages, summaryGenerator: nil)
        let compacted = try compactedMessages(from: messages, summary: Self.validatedSummary(from: response))
        return (compacted, response.tokenUsage ?? TokenUsage())
    }

    func compactedMessages(from messages: [ChatMessage], summary: String) -> [ChatMessage] {
        let taskContext = extractTaskContext(messages)
        let recentContext = extractRecentContext(messages).map { $0.strippingResponsesContinuationAnchorIfAssistant() }
        let bridge = Self.bridgeMessage(summary: summary)
        let acknowledgment = AssistantMessage(content: "Understood. Resuming from the checkpoint.")

        var compacted = taskContext
        compacted.append(bridge)
        compacted.append(.assistant(acknowledgment))
        compacted.append(contentsOf: recentContext)
        return compacted
    }

    static func truncateToolResult(_ content: String, maxCharacters: Int?) -> String {
        guard let max = maxCharacters else { return content }
        guard max > 0 else { return "" }
        guard content.count > max else { return content }
        let marker = Self.toolResultTruncationMarkers.first { $0.count <= max } ?? String(repeating: ".", count: max)
        guard marker.count < max else { return marker }
        let contentBudget = max - marker.count
        let headBudget = contentBudget * 3 / 5
        let tailBudget = contentBudget - headBudget
        return "\(content.prefix(headBudget))\(marker)\(content.suffix(tailBudget))"
    }

    static func truncateToolResult(_ result: ToolResult, maxCharacters: Int?) -> ToolResult {
        ToolResult(
            content: truncateToolResult(result.content, maxCharacters: maxCharacters),
            isError: result.isError
        )
    }

    private func truncateIfNeeded(_ messages: inout [ChatMessage]) -> Bool {
        guard let maxMessages = configuration.maxMessages else { return false }
        let truncated = messages.truncated(to: maxMessages, preservingSystemPrompt: true)
        guard truncated != messages else { return false }
        messages = truncated
        return true
    }
}

private extension ContextCompactor {
    static func validatedSummary(from response: AssistantMessage) throws -> String {
        guard response.toolCalls.isEmpty else {
            throw AgentError.llmError(
                .decodingFailed(description: "Compaction summary response included tool calls")
            )
        }
        let summary = extractSummary(from: response.content)
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.llmError(
                .decodingFailed(description: "Compaction summary response was empty")
            )
        }
        return summary
    }

    static func extractSummary(from response: String) -> String {
        guard let startRange = response.range(of: "<summary>"),
              let endRange = response[startRange.upperBound...].range(of: "</summary>")
        else {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let content = response[startRange.upperBound ..< endRange.lowerBound]
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        CRITICAL: Respond with TEXT ONLY. Do NOT call any tools. \
        Tool calls will be rejected and will waste this turn.

        You are performing a CONTEXT CHECKPOINT. Create a detailed handoff summary that \
        another instance of yourself could use to seamlessly resume this task.

        Your summary must include ALL of the following sections:

        1. Task and Objective
           What is the goal? What were the original instructions?

        2. All User Messages
           Reproduce every user message (not tool results) in order. \
        Use direct quotes. This prevents task drift across compaction boundaries.

        3. Current Progress
           - Key actions taken and their outcomes
           - Tools called and their significant results
           - Decisions made and their rationale

        4. Files and Code
           - Every file path that has been read, created, or modified
           - Function signatures, type definitions, and code snippets that matter \
        for continuing the work (not just file names)

        5. Errors and Fixes
           - Problems encountered and how they were resolved
           - User feedback or corrections that changed the approach

        6. Current State
           - What is working and verified?
           - What files or resources have been modified?
           - Any important data, values, or configurations

        7. Remaining Work
           - Outstanding tasks in priority order
           - Known issues or blockers

        8. Next Step
           - What should happen immediately when work resumes?
           - If the user gave specific instructions about what to do next, \
        quote their exact words

        Structure your response in two parts:

        First, an <analysis> block where you work through each section above. \
        This is your drafting scratchpad. Be thorough.

        Then, a <summary> block containing the final polished checkpoint. \
        Only the summary will be preserved in context. The analysis will be discarded.

        Write as if briefing a colleague who will take over immediately. Be specific: \
        include file paths, function names, and concrete values rather than vague descriptions.

        Do not call any tools. Respond with plain text only.
        """
    }
}
