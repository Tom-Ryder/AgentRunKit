import Foundation

/// A multi-turn conversation interface with optional tool calling and structured output.
///
/// For a guide, see <doc:AgentAndChat>.
public struct Chat<C: ToolContext>: Sendable {
    private let client: any LLMClient
    private let tools: [any AnyTool<C>]
    private let toolDefinitions: [ToolDefinition]
    private let systemPrompt: String?
    private let maxToolRounds: Int
    private let toolTimeout: Duration
    private let maxMessages: Int?
    private let maxToolResultCharacters: Int?
    private let approvalPolicy: ToolApprovalPolicy

    public init(
        client: any LLMClient,
        tools: [any AnyTool<C>] = [],
        systemPrompt: String? = nil,
        maxToolRounds: Int = 10,
        toolTimeout: Duration = .seconds(30),
        maxMessages: Int? = nil,
        maxToolResultCharacters: Int? = nil,
        approvalPolicy: ToolApprovalPolicy = .none
    ) {
        if let maxMessages {
            precondition(maxMessages >= 1, "maxMessages must be at least 1")
        }
        if let maxToolResultCharacters {
            precondition(maxToolResultCharacters >= 1, "maxToolResultCharacters must be at least 1")
        }
        self.client = client
        self.tools = tools
        toolDefinitions = tools.map { ToolDefinition($0) }
        self.systemPrompt = systemPrompt
        self.maxToolRounds = maxToolRounds
        self.toolTimeout = toolTimeout
        self.maxMessages = maxMessages
        self.maxToolResultCharacters = maxToolResultCharacters
        self.approvalPolicy = approvalPolicy
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
        var messages = initialMessages(systemPrompt: systemPrompt, history: history, userMessage: message)
        var truncatedMessages = truncateIfNeeded(messages)
        try truncatedMessages.validateForLLMRequest()
        let response = try await withPromptTooLongRecovery {
            try await client.generate(
                messages: truncatedMessages,
                tools: toolDefinitions,
                responseFormat: nil,
                requestContext: requestContext
            )
        } recover: {
            guard reactivelyTruncate(&truncatedMessages) else { return false }
            messages = truncatedMessages
            return true
        }
        messages.append(.assistant(response))
        return (response, messages)
    }

    public func send<T: Decodable & SchemaProviding>(
        _ message: String,
        history: [ChatMessage] = [],
        returning type: T.Type,
        requestContext: RequestContext? = nil
    ) async throws -> (result: T, history: [ChatMessage]) {
        try await sendStructured(
            .user(message), history: history, returning: type, requestContext: requestContext
        )
    }

    public func send<T: Decodable & SchemaProviding>(
        _ parts: [ContentPart],
        history: [ChatMessage] = [],
        returning type: T.Type,
        requestContext: RequestContext? = nil
    ) async throws -> (result: T, history: [ChatMessage]) {
        try await sendStructured(
            .user(parts), history: history, returning: type, requestContext: requestContext
        )
    }

    private func sendStructured<T: Decodable & SchemaProviding>(
        _ message: ChatMessage,
        history: [ChatMessage],
        returning _: T.Type,
        requestContext: RequestContext?
    ) async throws -> (result: T, history: [ChatMessage]) {
        try T.validateSchema()
        var messages = initialMessages(systemPrompt: systemPrompt, history: history, userMessage: message)
        var truncatedMessages = truncateIfNeeded(messages)
        try truncatedMessages.validateForLLMRequest()
        let response = try await withPromptTooLongRecovery {
            try await client.generate(
                messages: truncatedMessages,
                tools: [],
                responseFormat: .jsonSchema(T.self),
                requestContext: requestContext
            )
        } recover: {
            guard reactivelyTruncate(&truncatedMessages) else { return false }
            messages = truncatedMessages
            return true
        }
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
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            userMessage: .user(message), history: history, context: context,
            requestContext: requestContext, approvalHandler: approvalHandler
        )
    }

    public func stream(
        _ parts: [ContentPart],
        history: [ChatMessage] = [],
        context: C,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            userMessage: .user(parts), history: history, context: context,
            requestContext: requestContext, approvalHandler: approvalHandler
        )
    }

    private func stream(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        requestContext: RequestContext?,
        approvalHandler: ToolApprovalHandler?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        precondition(
            approvalPolicy == .none || approvalHandler != nil,
            "approvalHandler is required when approvalPolicy is not .none"
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(
                        userMessage: userMessage,
                        history: history,
                        context: context,
                        requestContext: requestContext,
                        approvalHandler: approvalHandler,
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
}

private extension Chat {
    func performStream(
        userMessage: ChatMessage,
        history: [ChatMessage],
        context: C,
        requestContext: RequestContext?,
        approvalHandler: ToolApprovalHandler?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var messages = initialMessages(systemPrompt: systemPrompt, history: history, userMessage: userMessage)
        var totalUsage = TokenUsage()
        var sessionAllowlist: Set<String> = []
        let policy = StreamPolicy.chat
        let eventFactory = StreamEventFactory(sessionID: nil, runID: nil, origin: .live)
        let processor = StreamProcessor(
            client: client, toolDefinitions: toolDefinitions, policy: policy,
            eventFactory: eventFactory
        )
        let emit = StreamEmitter(factory: eventFactory, continuation: continuation)

        for _ in 0 ..< maxToolRounds {
            try Task.checkCancellation()

            var truncatedMessages = truncateIfNeeded(messages)
            try truncatedMessages.validateForLLMRequest()
            var emittedOutput = false
            let iteration = try await withPromptTooLongRecovery {
                try await processor.process(
                    messages: truncatedMessages,
                    totalUsage: &totalUsage,
                    emittedOutput: &emittedOutput,
                    continuation: continuation,
                    requestContext: requestContext
                )
            } recover: {
                guard !emittedOutput, reactivelyTruncate(&truncatedMessages) else { return false }
                messages = truncatedMessages
                return true
            }

            messages.append(.assistant(iteration.toAssistantMessage()))

            if policy.shouldTerminateAfterIteration(toolCalls: iteration.toolCalls) {
                emit.yield(.finished(
                    tokenUsage: totalUsage, content: nil, reason: nil, history: messages
                ))
                continuation.finish()
                return
            }

            let runner = try makeToolRunner(
                for: iteration.toolCalls,
                messages: messages,
                context: context,
                approvalHandler: approvalHandler,
                emit: emit
            )

            for call in iteration.toolCalls {
                let result = try await resolveAndExecuteTool(
                    call, runner: runner, allowlist: &sessionAllowlist, emit: emit
                )
                let truncatedResult = truncatedToolResult(
                    result,
                    toolName: call.name,
                    tools: tools,
                    fallbackLimit: maxToolResultCharacters
                )
                emit.yield(.toolCallCompleted(id: call.id, name: call.name, result: truncatedResult))
                messages.append(.tool(id: call.id, name: call.name, content: truncatedResult.content))
            }
        }

        emit.yield(.finished(
            tokenUsage: totalUsage,
            content: nil,
            reason: .maxIterationsReached(limit: maxToolRounds),
            history: messages
        ))
        continuation.finish()
    }

    func truncateIfNeeded(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard let maxMessages else { return messages }
        return messages.truncated(to: maxMessages, preservingSystemPrompt: true)
    }

    func reactivelyTruncate(_ messages: inout [ChatMessage]) -> Bool {
        let target = messages.count / 2
        guard target >= 1 else { return false }
        let truncated = messages.truncated(to: target, preservingSystemPrompt: true)
        guard truncated.count < messages.count else { return false }
        messages = truncated
        return true
    }

    func makeToolRunner(
        for toolCalls: [ToolCall],
        messages: [ChatMessage],
        context: C,
        approvalHandler: ToolApprovalHandler?,
        emit: StreamEmitter
    ) throws -> ToolCallRunner<C> {
        let hasSubAgentCalls = toolCalls.contains {
            firstTool(named: $0.name, in: tools) is any SubAgentExecutableTool<C>
        }
        let executionContext = hasSubAgentCalls
            ? try context.withParentHistory(messages.resolvedPrefixForInheritance())
            : context
        return ToolCallRunner(
            context: executionContext,
            defaultTimeout: toolTimeout,
            approvalHandler: approvalHandler,
            subAgentDispatch: .streaming(SubAgentStreamWiring(
                emit: emit,
                parentSessionID: nil,
                parentDepth: currentDepth(of: context),
                historyEmissionDepthLimit: nil
            ))
        )
    }

    func resolveAndExecuteTool(
        _ call: ToolCall,
        runner: ToolCallRunner<C>,
        allowlist: inout Set<String>,
        emit: StreamEmitter
    ) async throws -> ToolResult {
        guard let tool = firstTool(named: call.name, in: tools) else {
            return .error(AgentError.toolNotFound(name: call.name).feedbackMessage)
        }

        guard let handler = runner.approvalHandler,
              approvalPolicy.requiresApproval(toolName: call.name, allowlist: allowlist)
        else {
            return try await runner.run(call, tool: tool)
        }

        switch try await resolveApproval(
            for: call, toolDescription: tool.description,
            handler: handler, allowlist: &allowlist, emit: emit
        ) {
        case let .approved(approvedCall):
            return try await runner.run(approvedCall, tool: tool)
        case let .denied(result):
            return result
        }
    }
}
