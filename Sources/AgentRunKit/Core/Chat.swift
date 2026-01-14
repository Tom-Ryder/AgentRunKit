import Foundation

public struct Chat<C: ToolContext>: Sendable {
    private let client: any LLMClient
    private let tools: [any AnyTool<C>]
    private let toolDefinitions: [ToolDefinition]
    private let systemPrompt: String?
    private let maxToolRounds: Int
    private let toolTimeout: Duration

    public init(
        client: any LLMClient,
        tools: [any AnyTool<C>] = [],
        systemPrompt: String? = nil,
        maxToolRounds: Int = 10,
        toolTimeout: Duration = .seconds(30)
    ) {
        self.client = client
        self.tools = tools
        toolDefinitions = tools.map { ToolDefinition($0) }
        self.systemPrompt = systemPrompt
        self.maxToolRounds = maxToolRounds
        self.toolTimeout = toolTimeout
    }

    public func send(_ message: String) async throws -> AssistantMessage {
        let messages = buildMessages(userMessage: message)
        return try await client.generate(messages: messages, tools: toolDefinitions)
    }

    public func send<T: Decodable & SchemaProviding>(
        _ message: String,
        returning _: T.Type
    ) async throws -> T {
        let messages = buildMessages(userMessage: message)
        let response = try await client.generate(
            messages: messages,
            tools: [],
            responseFormat: .jsonSchema(T.self)
        )
        do {
            return try JSONDecoder().decode(T.self, from: Data(response.content.utf8))
        } catch {
            throw AgentError.structuredOutputDecodingFailed(message: String(describing: error))
        }
    }

    public func stream(_ message: String, context: C) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(message: message, context: context, continuation: continuation)
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
        message: String,
        context: C,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var messages = buildMessages(userMessage: message)
        var totalUsage = TokenUsage()
        let policy = StreamPolicy.chat
        let processor = StreamProcessor(client: client, toolDefinitions: toolDefinitions, policy: policy)

        for _ in 0 ..< maxToolRounds {
            try Task.checkCancellation()

            let iteration = try await processor.process(
                messages: messages,
                totalUsage: &totalUsage,
                continuation: continuation
            )

            if policy.shouldTerminateAfterIteration(toolCalls: iteration.toolCalls) {
                continuation.yield(.finished(tokenUsage: totalUsage, content: nil, reason: nil))
                continuation.finish()
                return
            }

            messages.append(.assistant(AssistantMessage(
                content: iteration.content,
                toolCalls: iteration.toolCalls
            )))

            for call in iteration.toolCalls {
                let result = try await executeToolSafely(call, context: context)
                continuation.yield(.toolCallCompleted(id: call.id, name: call.name, result: result))
                messages.append(.tool(id: call.id, name: call.name, content: result.content))
            }
        }

        continuation.finish(throwing: AgentError.maxIterationsReached(iterations: maxToolRounds))
    }

    private func buildMessages(userMessage: String) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(userMessage))
        return messages
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
