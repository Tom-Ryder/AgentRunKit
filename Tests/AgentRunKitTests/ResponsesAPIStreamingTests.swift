@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesStreamingTests {
    private func makeClient() -> ResponsesAPIClient {
        ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
    }

    private static let completedJSON =
        #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","output":[],"#
            + #""usage":{"input_tokens":10,"output_tokens":5}}}"#

    private static let completedWithReasoningJSON =
        #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","output":[],"#
            + #""usage":{"input_tokens":50,"output_tokens":30,"output_tokens_details":{"reasoning_tokens":10}}}}"#

    @Test
    func textDeltaYieldsContent() async throws {
        let lines = [
            sseLine(#"{"type":"response.output_text.delta","delta":"Hello"}"#),
            sseLine(#"{"type":"response.output_text.delta","delta":" world"}"#),
            sseLine(Self.completedJSON)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        #expect(deltas.count == 3)
        #expect(deltas[0] == .content("Hello"))
        #expect(deltas[1] == .content(" world"))
        if case let .finished(usage) = deltas[2] {
            #expect(usage?.input == 10)
            #expect(usage?.output == 5)
        } else {
            Issue.record("Expected .finished")
        }
    }

    @Test
    func functionCallStartYieldsToolCallStart() async throws {
        let addedJSON =
            #"{"type":"response.output_item.added","output_index":0,"#
                + #""item":{"type":"function_call","call_id":"call_1","name":"search"}}"#
        let lines = [
            sseLine(addedJSON),
            sseLine(#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"q\":"}"#),
            sseLine(#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"\"test\"}"}"#),
            sseLine(Self.completedJSON)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        #expect(deltas.count == 4)
        #expect(deltas[0] == .toolCallStart(index: 0, id: "call_1", name: "search"))
        #expect(deltas[1] == .toolCallDelta(index: 0, arguments: "{\"q\":"))
        #expect(deltas[2] == .toolCallDelta(index: 0, arguments: "\"test\"}"))
    }

    @Test
    func completedEventYieldsFinished() async throws {
        let lines = [sseLine(Self.completedWithReasoningJSON)]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        #expect(deltas.count == 1)
        if case let .finished(usage) = deltas[0] {
            #expect(usage == TokenUsage(input: 50, output: 20, reasoning: 10))
        } else {
            Issue.record("Expected .finished")
        }
    }

    @Test
    func unknownEventsIgnored() async throws {
        let lines = [
            sseLine(#"{"type":"response.created","response":{}}"#),
            sseLine(#"{"type":"response.in_progress"}"#),
            sseLine(#"{"type":"response.output_text.delta","delta":"Hi"}"#),
            sseLine(Self.completedJSON)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        #expect(deltas.count == 2)
        #expect(deltas[0] == .content("Hi"))
    }

    @Test
    func failedEventThrowsError() async throws {
        let failedJSON = """
        {"type":"response.failed","response":{"error":{"message":"Rate limit exceeded","code":"rate_limit"}}}
        """
        let lines = [sseLine(failedJSON)]

        do {
            _ = try await collectStreamDeltas(client: makeClient(), lines: lines)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error else {
                Issue.record("Expected llmError, got \(error)")
                return
            }
            if case let .other(message) = transport {
                #expect(message.contains("Rate limit"))
            } else {
                Issue.record("Expected .other, got \(transport)")
            }
        }
    }

    @Test
    func reasoningSummaryDeltaYieldsReasoning() async throws {
        let lines = [
            sseLine(#"{"type":"response.reasoning_summary_text.delta","delta":"Thinking..."}"#),
            sseLine(Self.completedJSON)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        #expect(deltas.count == 2)
        #expect(deltas[0] == .reasoning("Thinking..."))
    }

    @Test
    func reasoningOutputItemDoneYieldsReasoningDetails() async throws {
        let doneJSON = """
        {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_001","summary_text":"Plan"}}
        """
        let lines = [
            sseLine(doneJSON),
            sseLine(Self.completedJSON)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        #expect(deltas.count == 2)
        if case let .reasoningDetails(details) = deltas[0] {
            #expect(details.count == 1)
            if case let .object(obj) = details[0] {
                #expect(obj["type"] == .string("reasoning"))
            } else {
                Issue.record("Expected object in reasoning details")
            }
        } else {
            Issue.record("Expected .reasoningDetails")
        }
    }

    private func sseLine(_ json: String) -> String {
        "data: \(json)"
    }

    private func collectStreamDeltas(
        client: ResponsesAPIClient,
        lines: [String]
    ) async throws -> [StreamDelta] {
        let allBytes = lines.joined(separator: "\n").appending("\n")
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()
        for byte in Array(allBytes.utf8) {
            byteContinuation.yield(byte)
        }
        byteContinuation.finish()

        let controlled = ControlledByteStream(stream: byteStream)
        let streamPair = AsyncThrowingStream<RunStreamElement, Error>.makeStream()

        try await client.processTestStream(
            byteStream: controlled,
            messagesCount: 0,
            continuation: streamPair.continuation
        )

        var collected: [StreamDelta] = []
        for try await element in streamPair.stream {
            guard case let .delta(delta) = element else { continue }
            collected.append(delta)
        }
        return collected
    }
}

extension ResponsesAPIClient {
    func processTestStream(
        byteStream: ControlledByteStream,
        messagesCount: Int,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        try await processSSEStream(bytes: byteStream, stallTimeout: nil) { [self] line in
            try await handleSSELine(
                line,
                messagesCount: messagesCount,
                continuation: continuation
            )
        }
        continuation.finish()
    }
}
