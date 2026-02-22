import Foundation

public struct Chat<C: ToolContext>: Sendable {
    private let client: any LLMClient
    private let tools: [any AnyTool<C>]
    private let toolDefinitions: [ToolDefinition]
    private let systemPrompt: String?
    private let maxToolRounds: Int
    private let toolTimeout: Duration
    private let maxMessages: Int?

    public init(
        client: any LLMClient,
        tools: [any AnyTool<C>] = [],
        systemPrompt: String? = nil,
        maxToolRounds: Int = 10,
        toolTimeout: Duration = .seconds(30),
        maxMessages: Int? = nil
    ) {
        if let maxMessages {
            precondition(maxMessages >= 1, "maxMessages must be at least 1")
        }
        self.client = client
        self.tools = tools
        toolDefinitions = tools.map { ToolDefinition($0) }
        self.systemPrompt = systemPrompt
        self.maxToolRounds = maxToolRounds
        self.toolTimeout = toolTimeout
        self.maxMessages = maxMessages
    }

    public func send(
        _ message: String,
        history: [ChatMessage] = [],
        requestContext: RequestContext? = nil
    ) async throws -> (response: AssistantMessage, history: [ChatMessage]) {
        try await send(.user(message), history: history, requestContext: requestContext)
    }

    public func send(
        _ parts: [ContentPart],
        history: [ChatMessage] = [],
        requestContext: RequestContext? = nil
    ) async throws -> (response: AssistantMessage, history: [ChatMessage]) {
        try await send(.user(parts), history: history, requestContext: requestContext)
    }

    public func send(
        _ message: ChatMessage,
        history: [ChatMessage] = [],
        requestContext: RequestContext? = nil
    ) async throws -> (response: AssistantMessage, history: [ChatMessage]) {
        var messages = buildMessages(userMessage: message, history: history)
        let truncatedMessages = truncateIfNeeded(messages)
        let response = try await client.generate(
            messages: truncatedMessages,
            tools: toolDefinitions,
            responseFormat: nil,
            requestContext: requestContext
        )
        messages.append(.assistant(response))
        return (response, messages)
    }

    public func send<T: Decodable & SchemaProviding>(
        _ message: String,
        history: [ChatMessage] = [],
        returning _: T.Type,
        requestContext: RequestContext? = nil
    ) async throws -> (result: T, history: [ChatMessage]) {
        try T.validateSchema()
        var messages = buildMessages(userMessage: .user(message), history: history)
        let truncatedMessages = truncateIfNeeded(messages)
        let response = try await client.generate(
            messages: truncatedMessages,
            tools: [],
            responseFormat: .jsonSchema(T.self),
            requestContext: requestContext
        )
        messages.append(.assistant(response))
        let result: T = try decodeStructuredOutput(response.content)
        return (result, messages)
    }

    public func send<T: Decodable & SchemaProviding>(
        _ parts: [ContentPart],
        history: [ChatMessage] = [],
        returning _: T.Type,
        requestContext: RequestContext? = nil
    ) async throws -> (result: T, history: [ChatMessage]) {
        try T.validateSchema()
        var messages = buildMessages(userMessage: .user(parts), history: history)
        let truncatedMessages = truncateIfNeeded(messages)
        let response = try await client.generate(
            messages: truncatedMessages,
            tools: [],
            responseFormat: .jsonSchema(T.self),
            requestContext: requestContext
        )
        messages.append(.assistant(response))
        let result: T = try decodeStructuredOutput(response.content)
        return (result, messages)
    }

    private func decodeStructuredOutput<T: Decodable>(_ content: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(content.utf8))
        } catch {
            throw AgentError.structuredOutputDecodingFailed(message: String(describing: error))
        }
    }

    public func stream(
        _ message: String,
        history: [ChatMessage] = [],
        context: C,
        requestContext: RequestContext? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(userMessage: .user(message), history: history, context: context, requestContext: requestContext)
    }

    public func stream(
        _ parts: [ContentPart],
        history: [ChatMessage] = [],
        context: C,
        requestContext: RequestContext? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(userMessage: .user(parts), history: history, context: context, requestContext: requestContext)
    }

    private func stream(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(
                        userMessage: userMessage,
                        history: history,
                        context: context,
                        requestContext: requestContext,
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
        requestContext: RequestContext?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var messages = buildMessages(userMessage: userMessage, history: history)
        var totalUsage = TokenUsage()
        let policy = StreamPolicy.chat
        let processor = StreamProcessor(client: client, toolDefinitions: toolDefinitions, policy: policy)

        for _ in 0 ..< maxToolRounds {
            try Task.checkCancellation()

            let truncatedMessages = truncateIfNeeded(messages)
            let iteration = try await processor.process(
                messages: truncatedMessages,
                totalUsage: &totalUsage,
                continuation: continuation,
                requestContext: requestContext
            )

            let reasoning = iteration.reasoning.isEmpty ? nil : ReasoningContent(content: iteration.reasoning)
            let details = iteration.reasoningDetails.isEmpty ? nil : iteration.reasoningDetails
            messages.append(.assistant(AssistantMessage(
                content: iteration.content,
                toolCalls: iteration.toolCalls,
                reasoning: reasoning,
                reasoningDetails: details
            )))

            if policy.shouldTerminateAfterIteration(toolCalls: iteration.toolCalls) {
                continuation.yield(.finished(tokenUsage: totalUsage, content: nil, reason: nil, history: messages))
                continuation.finish()
                return
            }

            for call in iteration.toolCalls {
                let result = try await executeToolSafely(call, context: context)
                continuation.yield(.toolCallCompleted(id: call.id, name: call.name, result: result))
                messages.append(.tool(id: call.id, name: call.name, content: result.content))
            }
        }

        continuation.finish(throwing: AgentError.maxIterationsReached(iterations: maxToolRounds))
    }

    private func buildMessages(userMessage: ChatMessage, history: [ChatMessage]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(contentsOf: history)
        messages.append(userMessage)
        return messages
    }

    private func truncateIfNeeded(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard let maxMessages else { return messages }
        return messages.truncated(to: maxMessages, preservingSystemPrompt: true)
    }

    private func executeToolSafely(_ call: ToolCall, context: C) async throws -> ToolResult {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return .error(AgentError.toolNotFound(name: call.name).feedbackMessage)
        }
        do {
            return try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    try await tool.execute(arguments: call.argumentsData, context: context)
                }
                group.addTask {
                    try await Task.sleep(for: toolTimeout)
                    throw AgentError.toolTimeout(tool: call.name)
                }

                guard let result = try await group.next() else {
                    return .error(AgentError.toolTimeout(tool: call.name).feedbackMessage)
                }
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentError {
            return .error(error.feedbackMessage)
        } catch {
            return .error("Tool failed: \(error)")
        }
    }
}
