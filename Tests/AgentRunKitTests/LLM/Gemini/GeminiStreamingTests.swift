@testable import AgentRunKit
import Foundation
import Testing

// swiftlint:disable line_length

struct GeminiStreamingTests {
    private func makeClient() -> GeminiClient {
        GeminiClient(apiKey: "test-key", model: "gemini-2.5-pro")
    }

    private func collectDeltas(
        from sseLines: [String],
        client: GeminiClient? = nil
    ) async throws -> [StreamDelta] {
        let geminiClient = client ?? makeClient()
        let state = GeminiStreamState()
        let streamPair = AsyncThrowingStream<StreamDelta, Error>.makeStream()
        let byteStream = makeByteStream(from: sseLines)

        try await processSSEStream(bytes: byteStream, stallTimeout: nil) { event in
            try await geminiClient.handleSSEEvent(
                event, state: state, continuation: streamPair.continuation
            )
        }
        streamPair.continuation.finish()

        var deltas: [StreamDelta] = []
        for try await delta in streamPair.stream {
            deltas.append(delta)
        }
        return deltas
    }

    private func makeByteStream(from sseLines: [String]) -> ControlledByteStream {
        let allBytes = sseLines.joined(separator: "\n\n").appending("\n\n")
        let (stream, continuation) = AsyncStream<UInt8>.makeStream()
        for byte in Array(allBytes.utf8) {
            continuation.yield(byte)
        }
        continuation.finish()
        return ControlledByteStream(stream: stream)
    }

    @Test
    func textStreaming() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hello\"}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\" world\"}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"!\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let contentDeltas = deltas.filter {
            if case .content = $0 { return true }; return false
        }
        #expect(contentDeltas.count == 3)
        #expect(contentDeltas[0] == .content("Hello"))
        #expect(contentDeltas[1] == .content(" world"))
        #expect(contentDeltas[2] == .content("!"))

        let finishedDeltas = deltas.filter {
            if case .finished = $0 { return true }; return false
        }
        #expect(finishedDeltas.count == 1)
        if case let .finished(usage) = finishedDeltas[0] {
            #expect(usage?.input == 10)
            #expect(usage?.output == 5)
        }
    }

    @Test
    func multilineSSEDataYieldsContent() async throws {
        let bytes = Array("""
        data: {"candidates":[{"content":{"role":"model",
        data: "parts":[{"text":"Hello"}]}}]}

        """.utf8)
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()
        for byte in bytes {
            byteContinuation.yield(byte)
        }
        byteContinuation.finish()

        let client = makeClient()
        let state = GeminiStreamState()
        let streamPair = AsyncThrowingStream<StreamDelta, Error>.makeStream()

        try await processSSEStream(bytes: ControlledByteStream(stream: byteStream), stallTimeout: nil) { event in
            try await client.handleSSEEvent(event, state: state, continuation: streamPair.continuation)
        }
        streamPair.continuation.finish()

        var deltas: [StreamDelta] = []
        for try await delta in streamPair.stream {
            deltas.append(delta)
        }
        #expect(deltas.contains(.content("Hello")))
    }

    @Test
    func functionCallStreaming() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"id\":\"call_01\",\"name\":\"get_weather\",\"args\":{\"city\":\"NYC\"}}}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":20,\"candidatesTokenCount\":15}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let startDeltas = deltas.filter {
            if case .toolCallStart = $0 { return true }; return false
        }
        #expect(startDeltas.count == 1)
        if case let .toolCallStart(index, id, name, _) = startDeltas[0] {
            #expect(index == 0)
            #expect(id == "call_01")
            #expect(name == "get_weather")
        }

        let argDeltas = deltas.filter {
            if case .toolCallDelta = $0 { return true }; return false
        }
        #expect(argDeltas.count == 1)
        if case let .toolCallDelta(index, arguments) = argDeltas[0] {
            #expect(index == 0)
            #expect(arguments.contains("NYC"))
        }
    }

    @Test
    func functionCallStreamingEmitsThoughtSignatureDetail() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"id\":\"call_01\",\"name\":\"get_weather\",\"args\":{\"city\":\"NYC\"}},\"thoughtSignature\":\"sig_fc\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":20,\"candidatesTokenCount\":15}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let detailDeltas = deltas.filter {
            if case .reasoningDetails = $0 { return true }; return false
        }
        #expect(detailDeltas.count == 1)
        if case let .reasoningDetails(details) = detailDeltas[0] {
            #expect(details.count == 1)
            if case let .object(dict) = details[0] {
                #expect(dict["type"] == .string("gemini.function_call"))
                #expect(dict["tool_call_id"] == .string("call_01"))
                #expect(dict["thought_signature"] == .string("sig_fc"))
            } else {
                Issue.record("Expected function-call reasoning detail")
            }
        }
    }

    @Test
    func thinkingStreaming() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Let me think...\",\"thought\":true}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"more thinking\",\"thought\":true,\"thoughtSignature\":\"sig123\"}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"The answer.\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":20,\"thoughtsTokenCount\":8}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let reasoningDeltas = deltas.filter {
            if case .reasoning = $0 { return true }; return false
        }
        #expect(reasoningDeltas.count == 2)
        #expect(reasoningDeltas[0] == .reasoning("Let me think..."))
        #expect(reasoningDeltas[1] == .reasoning("more thinking"))

        let contentDeltas = deltas.filter {
            if case .content = $0 { return true }; return false
        }
        #expect(contentDeltas.count == 1)
        #expect(contentDeltas[0] == .content("The answer."))

        let detailDeltas = deltas.filter {
            if case .reasoningDetails = $0 { return true }; return false
        }
        #expect(detailDeltas.count == 1)
    }

    @Test
    func thinkingDetailsEmittedOnFinish() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"thought1\",\"thought\":true,\"thoughtSignature\":\"sig1\"}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"result\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":20,\"thoughtsTokenCount\":5}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let detailDeltas = deltas.filter {
            if case .reasoningDetails = $0 { return true }; return false
        }
        #expect(detailDeltas.count == 1)
        if case let .reasoningDetails(details) = detailDeltas[0] {
            #expect(details.count == 1)
            if case let .object(dict) = details[0] {
                #expect(dict["type"] == .string("thinking"))
                #expect(dict["thinking"] == .string("thought1"))
                #expect(dict["signature"] == .string("sig1"))
            }
        }
    }

    @Test
    func tokenUsageInFinishedDelta() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hi\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":100,\"candidatesTokenCount\":50,\"thoughtsTokenCount\":10,\"cachedContentTokenCount\":20}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let finishedDeltas = deltas.filter {
            if case .finished = $0 { return true }; return false
        }
        #expect(finishedDeltas.count == 1)
        if case let .finished(usage) = finishedDeltas[0] {
            #expect(usage?.input == 100)
            #expect(usage?.output == 50)
            #expect(usage?.reasoning == 10)
            #expect(usage?.cacheRead == 20)
        }
    }

    @Test
    func emptyDataLineSkipped() async throws {
        let lines = [
            "",
            "event: message",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hi\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":2}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let contentDeltas = deltas.filter {
            if case .content = $0 { return true }; return false
        }
        #expect(contentDeltas.count == 1)
    }

    @Test
    func multipleFunctionCallsInStream() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"id\":\"call_a\",\"name\":\"search\",\"args\":{\"q\":\"first\"}}},{\"functionCall\":{\"id\":\"call_b\",\"name\":\"lookup\",\"args\":{\"id\":42}}}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":30,\"candidatesTokenCount\":20}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let startDeltas = deltas.filter {
            if case .toolCallStart = $0 { return true }; return false
        }
        #expect(startDeltas.count == 2)
        if case let .toolCallStart(index0, id0, name0, _) = startDeltas[0] {
            #expect(index0 == 0)
            #expect(id0 == "call_a")
            #expect(name0 == "search")
        }
        if case let .toolCallStart(index1, id1, name1, _) = startDeltas[1] {
            #expect(index1 == 1)
            #expect(id1 == "call_b")
            #expect(name1 == "lookup")
        }
    }

    @Test
    func functionCallWithoutIdGetsSyntheticId() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"search\",\"args\":{\"q\":\"test\"}}}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let startDeltas = deltas.filter {
            if case .toolCallStart = $0 { return true }; return false
        }
        #expect(startDeltas.count == 1)
        if case let .toolCallStart(_, id, _, _) = startDeltas[0] {
            #expect(id == "gemini_call_0")
        }
    }

    @Test
    func maxTokensFinishReasonYieldsFinished() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"truncated\"}]},\"finishReason\":\"MAX_TOKENS\"}],\"usageMetadata\":{\"promptTokenCount\":100,\"candidatesTokenCount\":50}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let finishedDeltas = deltas.filter {
            if case .finished = $0 { return true }; return false
        }
        #expect(finishedDeltas.count == 1)
    }

    @Test
    func noCandidatesChunkSkipped() async throws {
        let lines = [
            "data: {\"usageMetadata\":{\"promptTokenCount\":10}}",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hi\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let contentDeltas = deltas.filter {
            if case .content = $0 { return true }; return false
        }
        #expect(contentDeltas.count == 1)
    }

    @Test
    func safetyFinishReasonYieldsFinished() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[]},\"finishReason\":\"SAFETY\"}],\"usageMetadata\":{\"promptTokenCount\":50,\"candidatesTokenCount\":0}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let finishedDeltas = deltas.filter {
            if case .finished = $0 { return true }; return false
        }
        #expect(finishedDeltas.count == 1)
        if case let .finished(usage) = finishedDeltas[0] {
            #expect(usage?.input == 50)
        }
    }

    @Test
    func interleavedThinkingProducesSeparateBlocks() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"thought1\",\"thought\":true,\"thoughtSignature\":\"sig1\"}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"content1\"}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"thought2\",\"thought\":true,\"thoughtSignature\":\"sig2\"}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"content2\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":20,\"thoughtsTokenCount\":5}}",
        ]
        let deltas = try await collectDeltas(from: lines)

        let detailDeltas = deltas.filter {
            if case .reasoningDetails = $0 { return true }; return false
        }
        #expect(detailDeltas.count == 1)
        if case let .reasoningDetails(details) = detailDeltas[0] {
            #expect(details.count == 2)
            if case let .object(first) = details[0] {
                #expect(first["thinking"] == .string("thought1"))
                #expect(first["signature"] == .string("sig1"))
            }
            if case let .object(second) = details[1] {
                #expect(second["thinking"] == .string("thought2"))
                #expect(second["signature"] == .string("sig2"))
            }
        }
    }

    @Test
    func errorResponseInStreamThrows() async throws {
        let lines = [
            "data: {\"error\":{\"code\":429,\"message\":\"Rate limit exceeded\",\"status\":\"RESOURCE_EXHAUSTED\"}}",
        ]
        let client = makeClient()
        let state = GeminiStreamState()
        let continuation = AsyncThrowingStream<StreamDelta, Error>.makeStream()

        do {
            try await processSSEStream(bytes: makeByteStream(from: lines), stallTimeout: nil) { event in
                try await client.handleSSEEvent(event, state: state, continuation: continuation.continuation)
            }
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .other(msg) = transport
            else {
                Issue.record("Expected .other, got \(error)")
                return
            }
            #expect(msg.contains("RESOURCE_EXHAUSTED"))
            #expect(msg.contains("Rate limit exceeded"))
        }
    }
}

// swiftlint:enable line_length
