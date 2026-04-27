import AgentRunKit
import Foundation
import MLXLMCommon

public struct MLXClient: LLMClient, Sendable {
    public let container: ModelContainer
    public let modelIdentifier: String?
    public let contextWindowSize: Int?
    public let providerIdentifier: ProviderIdentifier = .mlx
    public let generateParameters: GenerateParameters

    public init(
        container: ModelContainer,
        model: String? = nil,
        contextWindowSize: Int? = nil,
        parameters: GenerateParameters = GenerateParameters()
    ) {
        self.container = container
        modelIdentifier = model
        self.contextWindowSize = contextWindowSize
        generateParameters = parameters
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        if responseFormat != nil {
            throw AgentError.llmError(.other("MLXClient does not support responseFormat"))
        }

        let genStream = try await runGeneration(
            messages: messages, tools: tools, requestContext: requestContext
        )

        var content = ""
        var toolCalls: [AgentRunKit.ToolCall] = []
        var toolCallIndex = 0
        var tokenUsage: TokenUsage?

        for await generation in genStream {
            switch generation {
            case let .chunk(text):
                content += text
            case let .toolCall(call):
                toolCalls.append(MLXMessageMapper.mapToolCall(call, index: toolCallIndex))
                toolCallIndex += 1
            case let .info(info):
                tokenUsage = TokenUsage(
                    input: info.promptTokenCount,
                    output: info.generationTokenCount
                )
            }
        }

        let (reasoning, cleanContent) = ThinkTagParser.extract(from: content)
        return AssistantMessage(
            content: cleanContent,
            toolCalls: toolCalls,
            tokenUsage: tokenUsage,
            reasoning: reasoning.isEmpty ? nil : ReasoningContent(content: reasoning)
        )
    }

    public func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let genStream = try await runGeneration(
                        messages: messages, tools: tools, requestContext: requestContext
                    )
                    var toolCallIndex = 0
                    var parser = ThinkTagParser()
                    for await generation in genStream {
                        switch generation {
                        case let .chunk(text):
                            let (reasoning, content) = parser.addContent(text)
                            if !reasoning.isEmpty { continuation.yield(.reasoning(reasoning)) }
                            if !content.isEmpty { continuation.yield(.content(content)) }
                        case let .toolCall(call):
                            let mapped = MLXMessageMapper.mapToolCall(call, index: toolCallIndex)
                            continuation.yield(.toolCallStart(
                                index: toolCallIndex, id: mapped.id, name: mapped.name, kind: .function
                            ))
                            continuation.yield(.toolCallDelta(
                                index: toolCallIndex, arguments: mapped.arguments
                            ))
                            toolCallIndex += 1
                        case let .info(info):
                            continuation.yield(.finished(usage: TokenUsage(
                                input: info.promptTokenCount,
                                output: info.generationTokenCount
                            )))
                        }
                    }
                    let (finalReasoning, finalContent) = parser.finalize()
                    if !finalReasoning.isEmpty { continuation.yield(.reasoning(finalReasoning)) }
                    if !finalContent.isEmpty { continuation.yield(.content(finalContent)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runGeneration(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) async throws -> AsyncStream<Generation> {
        try messages.validateForLLMRequest()
        let toolSpecs = tools.map(MLXMessageMapper.toolSpec)
        let messageDicts = MLXMessageMapper.mapMessages(messages)
        let mergedParams = MLXMessageMapper.mergeParameters(
            generateParameters,
            extraFields: requestContext?.extraFields ?? [:]
        )
        let userInput = UserInput(
            messages: messageDicts,
            tools: toolSpecs.isEmpty ? nil : toolSpecs
        )
        let prepared = try await container.prepare(input: userInput)
        return try await container.generate(input: prepared, parameters: mergedParams)
    }
}
