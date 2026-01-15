import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct ChatMultimodalTests {
    @Test
    func sendMultimodalPartsUsesUserMessage() async throws {
        let client = CapturingGenerateMockLLMClient(responses: [AssistantMessage(content: "OK")])
        let chat = Chat<EmptyContext>(client: client)
        let audioData = Data("audio".utf8)
        let parts: [ContentPart] = [.text("Transcribe"), .audio(data: audioData, format: .wav)]

        _ = try await chat.send(parts)

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 1)
        guard case let .userMultimodal(capturedParts) = capturedMessages[0] else {
            Issue.record("Expected user multimodal message")
            return
        }
        #expect(capturedParts == parts)
    }

    @Test
    func streamMultimodalPartsUsesUserMessage() async throws {
        let deltas: [StreamDelta] = [.content("OK"), .finished(usage: nil)]
        let client = CapturingStreamingMockLLMClient(streamSequences: [deltas])
        let chat = Chat<EmptyContext>(client: client)
        let audioData = Data("audio".utf8)
        let parts: [ContentPart] = [.text("Transcribe"), .audio(data: audioData, format: .wav)]

        for try await _ in chat.stream(parts, context: EmptyContext()) {}

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 1)
        guard case let .userMultimodal(capturedParts) = capturedMessages[0] else {
            Issue.record("Expected user multimodal message")
            return
        }
        #expect(capturedParts == parts)
    }
}

private actor CapturingGenerateMockLLMClient: LLMClient {
    private let responses: [AssistantMessage]
    private var callIndex = 0
    private(set) var capturedMessages: [ChatMessage] = []

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        capturedMessages = messages
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
