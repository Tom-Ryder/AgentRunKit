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
        var messages = buildMessages(userMessage: message, history: history)
        var truncatedMessages = truncateIfNeeded(messages)
        try truncatedMessages.validateForLLMRequest()
        do {
            let response = try await client.generate(
                messages: truncatedMessages,
                tools: toolDefinitions,
                responseFormat: nil,
                requestContext: requestContext
            )
            messages.append(.assistant(response))
            return (response, messages)
        } catch let AgentError.llmError(transport) where transport.isPromptTooLong {
            guard reactivelyTruncate(&truncatedMessages) else {
                throw AgentError.llmError(transport)
            }
            let response = try await client.generate(
                messages: truncatedMessages,
                tools: toolDefinitions,
                responseFormat: nil,
                requestContext: requestContext
            )
            messages = truncatedMessages
            messages.append(.assistant(response))
            return (response, messages)
        }
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
        var messages = buildMessages(userMessage: message, history: history)
        var truncatedMessages = truncateIfNeeded(messages)
        try truncatedMessages.validateForLLMRequest()
        do {
            let response = try await client.generate(
                messages: truncatedMessages,
                tools: [],
                responseFormat: .jsonSchema(T.self),
                requestContext: requestContext
            )
            messages.append(.assistant(response))
            let result: T = try decodeStructuredOutput(response.content)
            return (result, messages)
        } catch let AgentError.llmError(transport) where transport.isPromptTooLong {
            guard reactivelyTruncate(&truncatedMessages) else {
                throw AgentError.llmError(transport)
            }
            let response = try await client.generate(
                messages: truncatedMessages,
                tools: [],
                responseFormat: .jsonSchema(T.self),
                requestContext: requestContext
            )
            messages = truncatedMessages
            messages.append(.assistant(response))
            let result: T = try decodeStructuredOutput(response.content)
            return (result, messages)
        }
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
        var messages = buildMessages(userMessage: userMessage, history: history)
        var totalUsage = TokenUsage()
        var sessionAllowlist: Set<String> = []
        let policy = StreamPolicy.chat
        let processor = StreamProcessor(
            client: client, toolDefinitions: toolDefinitions, policy: policy,
            eventFactory: StreamEventFactory(sessionID: nil, runID: nil, origin: .live)
        )

        for _ in 0 ..< maxToolRounds {
            try Task.checkCancellation()

            var truncatedMessages = truncateIfNeeded(messages)
            try truncatedMessages.validateForLLMRequest()
            var emittedOutput = false
            let iteration: StreamIteration
            do {
                iteration = try await processor.process(
                    messages: truncatedMessages,
                    totalUsage: &totalUsage,
                    emittedOutput: &emittedOutput,
                    continuation: continuation,
                    requestContext: requestContext
                )
            } catch let AgentError.llmError(transport) where transport.isPromptTooLong {
                guard !emittedOutput, reactivelyTruncate(&truncatedMessages) else {
                    throw AgentError.llmError(transport)
                }
                iteration = try await processor.process(
                    messages: truncatedMessages,
                    totalUsage: &totalUsage,
                    continuation: continuation,
                    requestContext: requestContext
                )
                messages = truncatedMessages
            }

            messages.append(.assistant(iteration.toAssistantMessage()))

            if policy.shouldTerminateAfterIteration(toolCalls: iteration.toolCalls) {
                continuation.yield(.make(.finished(
                    tokenUsage: totalUsage, content: nil, reason: nil, history: messages
                )))
                continuation.finish()
                return
            }

            for call in iteration.toolCalls {
                let result = try await resolveAndExecuteTool(
                    call, context: context, approvalHandler: approvalHandler,
                    allowlist: &sessionAllowlist, continuation: continuation
                )
                let truncatedResult = truncatedToolResult(result, toolName: call.name)
                continuation.yield(.make(.toolCallCompleted(id: call.id, name: call.name, result: truncatedResult)))
                messages.append(.tool(id: call.id, name: call.name, content: truncatedResult.content))
            }
        }

        continuation.yield(.make(.finished(
            tokenUsage: totalUsage,
            content: nil,
            reason: .maxIterationsReached(limit: maxToolRounds),
            history: messages
        )))
        continuation.finish()
    }

    func buildMessages(userMessage: ChatMessage, history: [ChatMessage]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(contentsOf: history)
        messages.append(userMessage)
        return messages
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

    func toolResultCharacterLimit(for toolName: String) -> Int? {
        tool(named: toolName)?.maxResultCharacters ?? maxToolResultCharacters
    }

    func truncatedToolResult(_ result: ToolResult, toolName: String) -> ToolResult {
        ContextCompactor.truncateToolResult(result, maxCharacters: toolResultCharacterLimit(for: toolName))
    }

    func resolveTimeout(for tool: any AnyTool<C>) -> Duration {
        resolvedToolTimeout(for: tool, default: toolTimeout)
    }

    func resolveAndExecuteTool(
        _ call: ToolCall,
        context: C,
        approvalHandler: ToolApprovalHandler?,
        allowlist: inout Set<String>,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> ToolResult {
        guard let tool = tool(named: call.name) else {
            return .error(AgentError.toolNotFound(name: call.name).feedbackMessage)
        }

        guard let handler = approvalHandler,
              approvalPolicy.requiresApproval(toolName: call.name, allowlist: allowlist)
        else {
            return try await executeToolSafely(
                call,
                resolvedTool: tool,
                context: context,
                approvalHandler: approvalHandler
            )
        }

        let request = ToolApprovalRequest(
            toolCallId: call.id, toolName: call.name,
            arguments: call.arguments, toolDescription: tool.description
        )
        continuation.yield(.make(.toolApprovalRequested(request)))
        let decision = try await awaitApprovalDecision(for: request, using: handler)
        continuation.yield(.make(.toolApprovalResolved(toolCallId: call.id, decision: decision)))
        try Task.checkCancellation()

        switch decision {
        case .approve:
            return try await executeToolSafely(
                call,
                resolvedTool: tool,
                context: context,
                approvalHandler: approvalHandler
            )
        case .approveAlways:
            allowlist.insert(call.name)
            return try await executeToolSafely(
                call,
                resolvedTool: tool,
                context: context,
                approvalHandler: approvalHandler
            )
        case let .approveWithModifiedArguments(newArgs):
            let modified = ToolCall(
                id: call.id,
                name: call.name,
                arguments: newArgs,
                kind: call.kind
            )
            return try await executeToolSafely(
                modified,
                resolvedTool: tool,
                context: context,
                approvalHandler: approvalHandler
            )
        case let .deny(reason):
            return .error(reason ?? "Tool call was denied.")
        }
    }

    func executeToolSafely(
        _ call: ToolCall,
        resolvedTool: any AnyTool<C>,
        context: C,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> ToolResult {
        do {
            return try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    try await executeTool(
                        call,
                        with: resolvedTool,
                        context: context,
                        approvalHandler: approvalHandler
                    )
                }
                group.addTask {
                    try await Task.sleep(for: self.resolveTimeout(for: resolvedTool))
                    throw AgentError.toolTimeout(tool: call.name)
                }

                guard let result = try await group.next() else {
                    preconditionFailure("ThrowingTaskGroup with two tasks must yield a result")
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

    func executeTool(
        _ call: ToolCall,
        with tool: any AnyTool<C>,
        context: C,
        approvalHandler: ToolApprovalHandler?
    ) async throws -> ToolResult {
        if let handler = approvalHandler,
           let approvalAware = tool as? any ApprovalAwareSubAgentTool<C> {
            return try await approvalAware.executeWithApproval(
                arguments: call.argumentsData,
                context: context,
                approvalHandler: handler
            )
        }
        return try await tool.execute(arguments: call.argumentsData, context: context)
    }

    func tool(named name: String) -> (any AnyTool<C>)? {
        tools.first(where: { $0.name == name })
    }
}
