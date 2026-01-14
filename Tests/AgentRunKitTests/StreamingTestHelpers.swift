import Foundation

@testable import AgentRunKit

actor StreamingMockLLMClient: LLMClient {
    private let generateResponses: [AssistantMessage]
    private let streamSequences: [[StreamDelta]]
    private var generateIndex = 0
    private var streamIndex = 0

    init(generateResponses: [AssistantMessage] = [], streamSequences: [[StreamDelta]] = []) {
        self.generateResponses = generateResponses
        self.streamSequences = streamSequences
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        defer { generateIndex += 1 }
        guard generateIndex < generateResponses.count else {
            throw AgentError.llmError(.other("No more mock responses"))
        }
        return generateResponses[generateIndex]
    }

    func nextStreamSequence() -> [StreamDelta] {
        let sequence = streamIndex < streamSequences.count ? streamSequences[streamIndex] : []
        streamIndex += 1
        return sequence
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let sequence = await self.nextStreamSequence()
                    for delta in sequence {
                        try Task.checkCancellation()
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

actor GenerateOnlyMockLLMClient: LLMClient {
    private let responses: [AssistantMessage]
    private var callIndex = 0

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

actor CapturingStreamingMockLLMClient: LLMClient {
    private let streamSequences: [[StreamDelta]]
    private var streamIndex = 0
    private(set) var allCapturedMessages: [[ChatMessage]] = []

    var capturedMessages: [ChatMessage] {
        allCapturedMessages.last ?? []
    }

    init(streamSequences: [[StreamDelta]] = []) {
        self.streamSequences = streamSequences
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        throw AgentError.llmError(.other("No more mock responses"))
    }

    func nextStreamSequence(messages: [ChatMessage]) -> [StreamDelta] {
        allCapturedMessages.append(messages)
        let sequence = streamIndex < streamSequences.count ? streamSequences[streamIndex] : []
        streamIndex += 1
        return sequence
    }

    nonisolated func stream(
        messages: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let sequence = await self.nextStreamSequence(messages: messages)
                    for delta in sequence {
                        try Task.checkCancellation()
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

actor StreamingEventCollector {
    private(set) var events: [StreamEvent] = []

    func append(_ event: StreamEvent) {
        events.append(event)
    }
}

actor ControllableStreamingMockLLMClient: LLMClient {
    private var deltasContinuation: AsyncStream<StreamDelta>.Continuation?
    private var onStreamStarted: (() -> Void)?

    init() {}

    func setStreamStartedHandler(_ handler: @escaping () -> Void) {
        onStreamStarted = handler
    }

    func yieldDelta(_ delta: StreamDelta) {
        deltasContinuation?.yield(delta)
    }

    func finishStream() {
        deltasContinuation?.finish()
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        throw AgentError.llmError(.other("No more mock responses"))
    }

    func prepareStream() -> AsyncStream<StreamDelta> {
        AsyncStream { continuation in
            self.deltasContinuation = continuation
            self.onStreamStarted?()
        }
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let stream = await self.prepareStream()
                for await delta in stream {
                    try Task.checkCancellation()
                    continuation.yield(delta)
                }
                continuation.finish()
            }
        }
    }
}
