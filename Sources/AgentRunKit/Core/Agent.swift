import Foundation

public final class Agent<C: ToolContext>: Sendable {
    private let client: any LLMClient
    private let tools: [any AnyTool<C>]
    private let toolDefinitions: [ToolDefinition]
    private let configuration: AgentConfiguration

    public init(
        client: any LLMClient,
        tools: [any AnyTool<C>],
        configuration: AgentConfiguration = AgentConfiguration()
    ) {
        let names = tools.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }.keys
        precondition(duplicates.isEmpty, "Duplicate tool names: \(duplicates.sorted().joined(separator: ", "))")

        self.client = client
        self.tools = tools
        toolDefinitions = tools.map { ToolDefinition($0) } + [Self.finishToolDefinition]
        self.configuration = configuration
    }

    private static var finishToolDefinition: ToolDefinition {
        ToolDefinition(
            name: "finish",
            description: """
            Call this tool when you have completed the task. Pass the final result as content. \
            IMPORTANT: If called alongside other tools, those tools will NOT be executed.
            """,
            parametersSchema: .object(
                properties: [
                    "content": .string(description: "The final result or response to return to the user"),
                    "reason": .string(description: "Optional reason for finishing (e.g., 'completed', 'error')")
                        .optional()
                ],
                required: ["content"]
            )
        )
    }

    public func run(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C
    ) async throws -> AgentResult {
        try await run(userMessage: .user(userMessage), history: history, context: context)
    }

    public func run(
        userMessage: ChatMessage,
        history: [ChatMessage] = [],
        context: C
    ) async throws -> AgentResult {
        var messages = buildInitialMessages(userMessage: userMessage, history: history)

        var totalUsage = TokenUsage()

        for iteration in 1 ... configuration.maxIterations {
            try Task.checkCancellation()

            let truncatedMessages = truncateIfNeeded(messages)
            let response = try await client.generate(messages: truncatedMessages, tools: toolDefinitions)
            messages.append(.assistant(response))
            if let usage = response.tokenUsage { totalUsage += usage }

            if let finishCall = response.toolCalls.first(where: { $0.name == "finish" }) {
                return try parseFinishResult(
                    finishCall,
                    tokenUsage: totalUsage,
                    iterations: iteration,
                    history: messages
                )
            }

            if !response.toolCalls.isEmpty {
                let results = try await executeToolsInParallel(response.toolCalls, context: context)
                for (call, result) in results {
                    messages.append(.tool(id: call.id, name: call.name, content: result.content))
                }
            }
        }

        throw AgentError.maxIterationsReached(iterations: configuration.maxIterations)
    }

    private func truncateIfNeeded(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard let maxMessages = configuration.maxMessages else { return messages }
        return messages.truncated(to: maxMessages, preservingSystemPrompt: true)
    }

    public func stream(
        userMessage: String,
        history: [ChatMessage] = [],
        context: C
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(userMessage: .user(userMessage), history: history, context: context)
    }

    public func stream(
        userMessage: ChatMessage,
        history: [ChatMessage] = [],
        context: C
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(
                        userMessage: userMessage,
                        history: history,
                        context: context,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func performStream(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var messages = buildInitialMessages(userMessage: userMessage, history: history)
        var totalUsage = TokenUsage()
        let policy = StreamPolicy.agent
        let processor = StreamProcessor(client: client, toolDefinitions: toolDefinitions, policy: policy)

        for _ in 1 ... configuration.maxIterations {
            try Task.checkCancellation()

            let truncatedMessages = truncateIfNeeded(messages)
            let iteration = try await processor.process(
                messages: truncatedMessages,
                totalUsage: &totalUsage,
                continuation: continuation
            )

            let reasoning = iteration.reasoning.isEmpty ? nil : ReasoningContent(content: iteration.reasoning)
            messages.append(.assistant(AssistantMessage(
                content: iteration.content,
                toolCalls: iteration.toolCalls,
                reasoning: reasoning
            )))

            let executableTools = policy.executableToolCalls(from: iteration.toolCalls)
            if !executableTools.isEmpty {
                let results = try await executeToolsInParallel(executableTools, context: context)
                for (call, result) in results {
                    continuation.yield(.toolCallCompleted(id: call.id, name: call.name, result: result))
                    messages.append(.tool(id: call.id, name: call.name, content: result.content))
                }
            }

            if policy.shouldTerminateAfterIteration(toolCalls: iteration.toolCalls) {
                let finishEvent = try parseFinishEvent(from: iteration.toolCalls, tokenUsage: totalUsage, history: messages)
                continuation.yield(finishEvent)
                continuation.finish()
                return
            }
        }

        continuation.finish(throwing: AgentError.maxIterationsReached(iterations: configuration.maxIterations))
    }

    private func buildInitialMessages(userMessage: ChatMessage, history: [ChatMessage]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let systemPrompt = configuration.systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(contentsOf: history)
        messages.append(userMessage)
        return messages
    }

    private func executeWithTimeout(_ call: ToolCall, context: C) async throws -> ToolResult {
        do {
            return try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    try await self.executeTool(call, context: context)
                }
                group.addTask {
                    try await Task.sleep(for: self.configuration.toolTimeout)
                    throw AgentError.toolTimeout(tool: call.name)
                }

                guard let result = try await group.next() else {
                    throw AgentError.toolTimeout(tool: call.name)
                }
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentError {
            return ToolResult.error(error.feedbackMessage)
        } catch {
            return ToolResult.error("Tool failed: \(error)")
        }
    }

    private func executeToolsInParallel(
        _ calls: [ToolCall],
        context: C
    ) async throws -> [(call: ToolCall, result: ToolResult)] {
        try await withThrowingTaskGroup(of: (Int, ToolCall, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let result = try await self.executeWithTimeout(call, context: context)
                    return (index, call, result)
                }
            }

            var results = [(Int, ToolCall, ToolResult)]()
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }
}

private extension Agent {
    func executeTool(_ call: ToolCall, context: C) async throws -> ToolResult {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            throw AgentError.toolNotFound(name: call.name)
        }
        return try await tool.execute(arguments: call.argumentsData, context: context)
    }

    func parseFinishEvent(from toolCalls: [ToolCall], tokenUsage: TokenUsage, history: [ChatMessage]) throws -> StreamEvent {
        guard let finishCall = toolCalls.first(where: { $0.name == "finish" }) else {
            return .finished(tokenUsage: tokenUsage, content: nil, reason: nil, history: history)
        }
        let decoded: FinishArguments
        do {
            decoded = try JSONDecoder().decode(FinishArguments.self, from: finishCall.argumentsData)
        } catch {
            throw AgentError.finishDecodingFailed(message: String(describing: error))
        }
        return .finished(
            tokenUsage: tokenUsage,
            content: decoded.content,
            reason: FinishReason(decoded.reason ?? "completed"),
            history: history
        )
    }

    func parseFinishResult(
        _ call: ToolCall,
        tokenUsage: TokenUsage,
        iterations: Int,
        history: [ChatMessage]
    ) throws -> AgentResult {
        let data = call.argumentsData
        let decoded: FinishArguments
        do {
            decoded = try JSONDecoder().decode(FinishArguments.self, from: data)
        } catch {
            throw AgentError.finishDecodingFailed(message: String(describing: error))
        }
        return AgentResult(
            finishReason: FinishReason(decoded.reason ?? "completed"),
            content: decoded.content,
            totalTokenUsage: tokenUsage,
            iterations: iterations,
            history: history
        )
    }
}

private struct FinishArguments: Codable, Sendable {
    let content: String
    let reason: String?
}
