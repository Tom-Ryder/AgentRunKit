import Foundation

extension Agent {
    func executeRunIteration(
        messages: inout [ChatMessage],
        totalUsage: inout TokenUsage,
        lastTotalTokens: inout Int?,
        compactor: inout ContextCompactor,
        historyWasRewrittenLocally: inout Bool,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        let compactionOutcome = try await compactor.compactOrTruncateIfNeeded(
            &messages,
            lastTotalTokens: lastTotalTokens,
            totalUsage: &totalUsage,
            summaryGenerator: makeSummaryGenerator(for: historyWasRewrittenLocally)
        )
        if compactionOutcome.didRewriteHistory {
            historyWasRewrittenLocally = true
        }

        let response = try await generateRunResponse(
            messages: &messages,
            totalUsage: &totalUsage,
            compactor: &compactor,
            historyWasRewrittenLocally: &historyWasRewrittenLocally,
            requestContext: requestContext
        )
        messages.append(.assistant(response))
        if let usage = response.tokenUsage {
            totalUsage += usage
            lastTotalTokens = usage.total
        }
        return response
    }

    func generateRunResponse(
        messages: inout [ChatMessage],
        totalUsage: inout TokenUsage,
        compactor: inout ContextCompactor,
        historyWasRewrittenLocally: inout Bool,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        var attemptedReactiveRecovery = false

        while true {
            do {
                let response = try await client.generateForRun(
                    messages: messages,
                    tools: toolDefinitions,
                    responseFormat: nil,
                    requestContext: requestContext,
                    requestMode: requestMode(for: historyWasRewrittenLocally)
                )
                historyWasRewrittenLocally = false
                return response
            } catch let AgentError.llmError(transport) where transport.isPromptTooLong {
                guard !attemptedReactiveRecovery else {
                    throw AgentError.llmError(transport)
                }
                attemptedReactiveRecovery = true
                let reactiveOutcome = try await compactor.reactiveCompact(
                    &messages,
                    totalUsage: &totalUsage,
                    summaryGenerator: makeSummaryGenerator(for: historyWasRewrittenLocally)
                )
                guard reactiveOutcome.didRewriteHistory else {
                    throw AgentError.llmError(transport)
                }
                historyWasRewrittenLocally = true
            }
        }
    }

    func requestMode(for historyWasRewrittenLocally: Bool) -> RunRequestMode {
        historyWasRewrittenLocally ? .forceFullRequest : .auto
    }

    func makeSummaryGenerator(
        for historyWasRewrittenLocally: Bool
    ) -> ContextCompactor.SummaryGenerator {
        let mode = requestMode(for: historyWasRewrittenLocally)
        return { summaryRequest in
            try await self.client.generateForRun(
                messages: summaryRequest,
                tools: [],
                responseFormat: nil,
                requestContext: nil,
                requestMode: mode
            )
        }
    }

    func parseFinishResult(
        _ call: ToolCall,
        tokenUsage: TokenUsage,
        iterations: Int,
        history: [ChatMessage]
    ) throws -> AgentResult {
        let decoded = try decodeFinishArguments(from: call.argumentsData)
        return try AgentResult(
            finishReason: FinishReason(decoded.reason ?? "completed"),
            content: decoded.content,
            totalTokenUsage: tokenUsage,
            iterations: iterations,
            history: history.sanitizedTerminalHistory()
        )
    }

    func makeTerminalResult(
        reason: FinishReason,
        tokenUsage: TokenUsage,
        iterations: Int,
        history: [ChatMessage]
    ) -> AgentResult {
        AgentResult(
            finishReason: reason,
            content: nil,
            totalTokenUsage: tokenUsage,
            iterations: iterations,
            history: history
        )
    }
}
