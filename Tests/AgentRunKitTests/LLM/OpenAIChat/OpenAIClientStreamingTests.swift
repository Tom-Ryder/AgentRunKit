@testable import AgentRunKit
import Foundation
import Testing

struct OpenAIChatStreamingReasoningTests {
    private func makeClient(baseURL: URL, session: URLSession) -> OpenAIClient {
        OpenAIClient(
            apiKey: "test-key",
            model: "anthropic/claude-opus-4.8",
            baseURL: baseURL,
            session: session,
            assistantReplayProfile: .openRouterReasoningDetails
        )
    }

    private func sseLine(_ json: String) -> String {
        "data: \(json)"
    }

    private func reasoningEvent(_ detail: String) -> String {
        sseLine(#"{"choices":[{"index":0,"delta":{"reasoning_details":[\#(detail)]}}]}"#)
    }

    private func reasoningDetailsStreamBody() -> Data {
        let hello = #"{"type":"reasoning.text","format":"anthropic-claude-v1","index":0,"text":"Hello"}"#
        let world = #"{"type":"reasoning.text","format":"anthropic-claude-v1","index":0,"text":" world"}"#
        let signature = #"{"type":"reasoning.text","format":"anthropic-claude-v1","index":0,"signature":"sig-abc"}"#
        let events = [
            reasoningEvent(hello),
            reasoningEvent(world),
            reasoningEvent(signature),
            sseLine(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
        ]
        return Data((events.joined(separator: "\n\n") + "\n\ndata: [DONE]\n\n").utf8)
    }

    @Test
    func streamingReasoningDetailDeltasDecodedFromBytes() async throws {
        let session = URLSession(configuration: StreamingTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client = try makeClient(
            baseURL: #require(URL(string: "https://openrouter-reasoning-deltas.test/v1")),
            session: session
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [], stream: true)
        let requestURL = try #require(client.buildURLRequest(request).url)
        StreamingTestURLProtocol.register(url: requestURL, body: reasoningDetailsStreamBody())
        defer { StreamingTestURLProtocol.unregister(url: requestURL) }

        let (deltas, error) = await collectStreamResult(
            client.stream(messages: [.user("Hi")], tools: [], requestContext: nil)
        )
        #expect(error == nil)

        let reasoningDeltas = deltas.compactMap { delta -> [JSONValue]? in
            guard case let .reasoningDetails(details) = delta else { return nil }
            return details
        }
        #expect(reasoningDeltas.count == 1)
        #expect(reasoningDeltas.first == [.object([
            "type": .string("reasoning.text"),
            "format": .string("anthropic-claude-v1"),
            "index": .int(0),
            "text": .string("Hello world"),
            "signature": .string("sig-abc"),
        ])])
    }

    @Test
    func streamingReasoningDetailsConsolidateIntoSingleBlock() async throws {
        let session = URLSession(configuration: StreamingTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client = try makeClient(
            baseURL: #require(URL(string: "https://openrouter-reasoning-merge.test/v1")),
            session: session
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [], stream: true)
        let requestURL = try #require(client.buildURLRequest(request).url)
        StreamingTestURLProtocol.register(url: requestURL, body: reasoningDetailsStreamBody())
        defer { StreamingTestURLProtocol.unregister(url: requestURL) }

        let processor = StreamProcessor(
            client: client,
            toolDefinitions: [],
            policy: .chat,
            eventFactory: StreamEventFactory(sessionID: nil, runID: nil, origin: .live)
        )
        let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsage()
        var emittedOutput = false
        let iteration = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
            emittedOutput: &emittedOutput,
            continuation: continuation
        )

        let details = try #require(iteration.toAssistantMessage().reasoningDetails)
        #expect(details.count == 1)
        #expect(details[0] == .object([
            "type": .string("reasoning.text"),
            "format": .string("anthropic-claude-v1"),
            "index": .int(0),
            "text": .string("Hello world"),
            "signature": .string("sig-abc"),
        ]))
    }
}

struct OpenAIClientStreamingCompletionTests {
    private func collectStream(
        host: String,
        body: String,
        profile: OpenAIChatProfile = .compatible
    ) async throws -> (deltas: [StreamDelta], error: (any Error)?) {
        let session = URLSession(configuration: StreamingTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client = try OpenAIClient(
            apiKey: "test-key",
            model: "test-model",
            baseURL: #require(URL(string: "https://\(host).test/v1")),
            session: session,
            profile: profile
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [], stream: true)
        let urlRequest = try client.buildURLRequest(request)
        let requestURL = try #require(urlRequest.url)
        StreamingTestURLProtocol.register(url: requestURL, body: Data(body.utf8))
        defer { StreamingTestURLProtocol.unregister(url: requestURL) }
        return await collectStreamResult(client.stream(messages: [.user("Hi")], tools: [], requestContext: nil))
    }

    private func sseChunk(_ json: String) -> String {
        "data: \(json)\n\n"
    }

    @Test
    func streamEndingBeforeFinishThrowsProviderTerminationMissing() async throws {
        let result = try await collectStream(
            host: "chat-truncation",
            body: sseChunk(#"{"choices":[{"delta":{"content":"partial"},"index":0}]}"#)
        )

        #expect(result.deltas == [.content("partial")])
        guard case let .llmError(.streamFailed(.providerTerminationMissing(diagnostics))) =
            result.error as? AgentError
        else {
            Issue.record("Expected providerTerminationMissing, got \(String(describing: result.error))")
            return
        }
        #expect(!diagnostics.finishSignalSeen)
        #expect(diagnostics.provider == .openAICompatible)
    }

    @Test
    func eofAfterTerminalFinishCompletesWithoutDoneSentinel() async throws {
        let result = try await collectStream(
            host: "chat-eof-finish",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hello"},"index":0}]}"#)
                + sseChunk(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        )

        #expect(result.error == nil)
        #expect(result.deltas == [
            .content("Hello"),
            .finished(usage: nil),
            .streamClosed(terminalMarkerSeen: false),
        ])
    }

    @Test
    func eofAfterFinishAndTrailingUsageChunkPreservesUsage() async throws {
        let usageChunk = #"{"usage":{"prompt_tokens":11,"completion_tokens":12,"#
            + #""completion_tokens_details":{"reasoning_tokens":5}}}"#
        let result = try await collectStream(
            host: "chat-eof-usage",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hello"},"index":0}]}"#)
                + sseChunk(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
                + sseChunk(usageChunk)
        )

        #expect(result.error == nil)
        #expect(result.deltas == [
            .content("Hello"),
            .finished(usage: TokenUsage(input: 11, output: 7, reasoning: 5)),
            .streamClosed(terminalMarkerSeen: false),
        ])
    }

    @Test
    func doneAfterSeparateUsageChunkEmitsExactlyOneFinished() async throws {
        let result = try await collectStream(
            host: "chat-done-usage",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hello"},"index":0}]}"#)
                + sseChunk(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
                + sseChunk(#"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":50}}"#)
                + "data: [DONE]\n\n"
        )

        #expect(result.error == nil)
        #expect(result.deltas == [
            .content("Hello"),
            .finished(usage: TokenUsage(input: 100, output: 50)),
            .streamClosed(terminalMarkerSeen: true),
        ])
    }

    @Test
    func eofAfterToolCallFinishCompletes() async throws {
        let toolChunk = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","#
            + #""function":{"name":"lookup","arguments":"{}"}}]},"index":0}]}"#
        let result = try await collectStream(
            host: "chat-eof-tools",
            body: sseChunk(toolChunk)
                + sseChunk(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        )

        #expect(result.error == nil)
        #expect(result.deltas == [
            .toolCallStart(index: 0, id: "call_1", name: "lookup", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: nil),
            .streamClosed(terminalMarkerSeen: false),
        ])
    }

    @Test
    func midStreamErrorFrameThrowsProviderError() async throws {
        let errorFrame = #"{"id":"cmpl-1","object":"chat.completion.chunk","created":1,"model":"m","#
            + #""provider":"openai","error":{"code":"server_error","message":"Provider disconnected"},"#
            + #""choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#
        let result = try await collectStream(
            host: "chat-error-frame",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hi"},"index":0}]}"#) + sseChunk(errorFrame),
            profile: .openRouter
        )

        #expect(result.deltas == [.content("Hi")])
        guard case let .llmError(.streamFailed(.providerError(code, message, diagnostics))) =
            result.error as? AgentError
        else {
            Issue.record("Expected providerError, got \(String(describing: result.error))")
            return
        }
        #expect(code == "server_error")
        #expect(message == "Provider disconnected")
        #expect(diagnostics.provider == .openRouter)
    }

    @Test
    func midStreamErrorFrameWithNumericCodeNormalizesToString() async throws {
        let errorFrame = #"{"error":{"code":402,"message":"Insufficient credits"},"#
            + #""choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#
        let result = try await collectStream(host: "chat-error-numeric", body: sseChunk(errorFrame))

        guard case let .llmError(.streamFailed(.providerError(code, message, _))) =
            result.error as? AgentError
        else {
            Issue.record("Expected providerError, got \(String(describing: result.error))")
            return
        }
        #expect(code == "402")
        #expect(message == "Insufficient credits")
    }

    @Test
    func bareStringErrorFrameThrowsProviderError() async throws {
        let result = try await collectStream(
            host: "chat-error-string",
            body: sseChunk(#"{"error":"upstream_truncated"}"#)
        )

        #expect(result.deltas.isEmpty)
        guard case let .llmError(.streamFailed(.providerError(code, message, _))) =
            result.error as? AgentError
        else {
            Issue.record("Expected providerError, got \(String(describing: result.error))")
            return
        }
        #expect(code == nil)
        #expect(message == "upstream_truncated")
    }

    @Test
    func finishReasonErrorWithoutPayloadThrowsProviderError() async throws {
        let result = try await collectStream(
            host: "chat-error-bare-finish",
            body: sseChunk(#"{"choices":[{"delta":{},"finish_reason":"error"}]}"#)
        )

        #expect(result.deltas.isEmpty)
        guard case let .llmError(.streamFailed(.providerError(code, message, _))) =
            result.error as? AgentError
        else {
            Issue.record("Expected providerError, got \(String(describing: result.error))")
            return
        }
        #expect(code == nil)
        #expect(message.contains("finish_reason"))
    }

    @Test
    func usageChunkWithoutFinishReasonDoesNotCompleteAtEOF() async throws {
        let result = try await collectStream(
            host: "chat-usage-no-finish",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hi"},"index":0}]}"#)
                + sseChunk(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#)
        )

        #expect(result.deltas == [.content("Hi")])
        guard case let .llmError(.streamFailed(.providerTerminationMissing(diagnostics))) =
            result.error as? AgentError
        else {
            Issue.record("Expected providerTerminationMissing, got \(String(describing: result.error))")
            return
        }
        #expect(!diagnostics.finishSignalSeen)
    }

    @Test
    func emptyMessageErrorFrameThrowsProviderErrorWithFallbackMessage() async throws {
        let result = try await collectStream(
            host: "chat-error-empty-message",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hi"},"index":0}]}"#)
                + sseChunk(#"{"error":{"code":"server_error","message":""}}"#)
                + sseChunk(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        )

        #expect(result.deltas == [.content("Hi")])
        guard case let .llmError(.streamFailed(.providerError(code, message, _))) =
            result.error as? AgentError
        else {
            Issue.record("Expected providerError, got \(String(describing: result.error))")
            return
        }
        #expect(code == "server_error")
        #expect(message == "Provider returned an error without a message")
    }

    @Test
    func errorFrameWithoutMessageKeyThrowsProviderError() async throws {
        let result = try await collectStream(
            host: "chat-error-no-message",
            body: sseChunk(#"{"error":{"type":"overloaded"}}"#)
        )

        #expect(result.deltas.isEmpty)
        guard case let .llmError(.streamFailed(.providerError(code, message, _))) =
            result.error as? AgentError
        else {
            Issue.record("Expected providerError, got \(String(describing: result.error))")
            return
        }
        #expect(code == nil)
        #expect(message == "Provider returned an error without a message")
    }

    @Test
    func emptyBareStringErrorFrameFailsDecoding() async throws {
        let result = try await collectStream(
            host: "chat-error-empty-string",
            body: sseChunk(#"{"error":""}"#)
        )

        guard case .llmError(.decodingFailed) = result.error as? AgentError else {
            Issue.record("Expected decodingFailed, got \(String(describing: result.error))")
            return
        }
    }

    @Test
    func nullErrorKeyIsNotAnErrorFrame() async throws {
        let result = try await collectStream(
            host: "chat-error-null",
            body: sseChunk(#"{"error":null}"#)
                + sseChunk(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        )

        #expect(result.error == nil)
        #expect(result.deltas == [
            .finished(usage: nil),
            .streamClosed(terminalMarkerSeen: false),
        ])
    }

    @Test
    func doneWithoutFinishReasonThrowsFinishedDeltaMissing() async throws {
        let result = try await collectStream(
            host: "chat-done-no-finish",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hi"},"index":0}]}"#)
                + "data: [DONE]\n\n"
        )

        #expect(result.deltas == [.content("Hi")])
        guard case let .llmError(.streamFailed(.finishedDeltaMissing(diagnostics))) =
            result.error as? AgentError
        else {
            Issue.record("Expected finishedDeltaMissing, got \(String(describing: result.error))")
            return
        }
        #expect(!diagnostics.finishSignalSeen)
        #expect(diagnostics.provider == .openAICompatible)
    }

    @Test
    func usageThenDoneWithoutFinishReasonThrowsFinishedDeltaMissing() async throws {
        let result = try await collectStream(
            host: "chat-usage-done-no-finish",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hi"},"index":0}]}"#)
                + sseChunk(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#)
                + "data: [DONE]\n\n"
        )

        #expect(result.deltas == [.content("Hi")])
        guard case .llmError(.streamFailed(.finishedDeltaMissing)) = result.error as? AgentError else {
            Issue.record("Expected finishedDeltaMissing, got \(String(describing: result.error))")
            return
        }
    }

    @Test
    func finishChunkWithInlineUsageEmitsSingleFinishedWithUsage() async throws {
        let finishChunk = #"{"choices":[{"delta":{},"finish_reason":"stop"}],"#
            + #""usage":{"prompt_tokens":11,"completion_tokens":12,"#
            + #""completion_tokens_details":{"reasoning_tokens":5}}}"#
        let result = try await collectStream(
            host: "chat-inline-usage",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hi"},"index":0}]}"#)
                + sseChunk(finishChunk)
                + "data: [DONE]\n\n"
        )

        #expect(result.error == nil)
        #expect(result.deltas == [
            .content("Hi"),
            .finished(usage: TokenUsage(input: 11, output: 7, reasoning: 5)),
            .streamClosed(terminalMarkerSeen: true),
        ])
    }

    @Test
    func errorFrameAfterFinishReasonStillThrowsProviderError() async throws {
        let result = try await collectStream(
            host: "chat-error-after-finish",
            body: sseChunk(#"{"choices":[{"delta":{"content":"Hi"},"index":0}]}"#)
                + sseChunk(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
                + sseChunk(#"{"error":{"code":"server_error","message":"Upstream billing failure"}}"#)
        )

        #expect(result.deltas == [.content("Hi")])
        guard case let .llmError(.streamFailed(.providerError(code, message, diagnostics))) =
            result.error as? AgentError
        else {
            Issue.record("Expected providerError, got \(String(describing: result.error))")
            return
        }
        #expect(code == "server_error")
        #expect(message == "Upstream billing failure")
        #expect(diagnostics.finishSignalSeen)
    }
}
