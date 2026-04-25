@testable import AgentRunKit
import Foundation
import Testing

struct AnthropicStreamingTests {
    private func makeClient() throws -> AnthropicClient {
        try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
    }

    private func sseLine(_ json: String) -> String {
        "data: \(json)"
    }

    private func collectStreamDeltas(
        client: AnthropicClient,
        lines: [String]
    ) async throws -> [StreamDelta] {
        let allBytes = lines.joined(separator: "\n\n").appending("\n\n")
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()
        for byte in Array(allBytes.utf8) {
            byteContinuation.yield(byte)
        }
        byteContinuation.finish()

        let controlled = ControlledByteStream(stream: byteStream)
        let streamPair = AsyncThrowingStream<StreamDelta, Error>.makeStream()

        try await client.processTestStream(
            byteStream: controlled,
            continuation: streamPair.continuation
        )

        var collected: [StreamDelta] = []
        for try await delta in streamPair.stream {
            collected.append(delta)
        }
        return collected
    }

    @Test
    func textDeltaYieldsContent() async throws {
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":10}}"#),
            sseLine(#"{"type":"message_stop"}"#)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let contentDeltas = deltas.filter { if case .content = $0 { return true }; return false }
        #expect(contentDeltas.count == 2)
        #expect(contentDeltas[0] == .content("Hello"))
        #expect(contentDeltas[1] == .content(" world"))
    }

    @Test
    func multilineSSEDataYieldsContent() async throws {
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,
            data: "delta":{"type":"text_delta","text":"Hello"}}
            """,
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_stop"}"#),
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        #expect(deltas.contains(.content("Hello")))
    }

    @Test
    func thinkingDeltaYieldsReasoning() async throws {
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"s1"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}"#),
            sseLine(#"{"type":"content_block_stop","index":1}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":20}}"#),
            sseLine(#"{"type":"message_stop"}"#)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let reasoningDeltas = deltas.filter { if case .reasoning = $0 { return true }; return false }
        #expect(reasoningDeltas.count == 1)
        #expect(reasoningDeltas[0] == .reasoning("hmm"))

        let detailDeltas = deltas.filter { if case .reasoningDetails = $0 { return true }; return false }
        #expect(detailDeltas.count == 1)
        if case let .reasoningDetails(details) = detailDeltas[0],
           case let .object(dict) = details[0] {
            #expect(dict["type"] == .string("thinking"))
            #expect(dict["thinking"] == .string("hmm"))
            #expect(dict["signature"] == .string("s1"))
        } else {
            Issue.record("Expected reasoningDetails with thinking/signature object")
        }
    }

    @Test
    func toolUseStreaming() async throws {
        let toolStart = #"{"type":"content_block_start","index":0,"content_block":"#
            + #"{"type":"tool_use","id":"toolu_01","name":"search"}}"#
        let argDelta1 = #"{"type":"content_block_delta","index":0,"delta":"#
            + #"{"type":"input_json_delta","partial_json":"{\"q\":"}}"#
        let argDelta2 = #"{"type":"content_block_delta","index":0,"delta":"#
            + #"{"type":"input_json_delta","partial_json":"\"test\"}"}}"#
        let lines = [
            sseLine(toolStart),
            sseLine(argDelta1),
            sseLine(argDelta2),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":15}}"#),
            sseLine(#"{"type":"message_stop"}"#)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let starts = deltas.filter { if case .toolCallStart = $0 { return true }; return false }
        #expect(starts.count == 1)
        #expect(starts[0] == .toolCallStart(index: 0, id: "toolu_01", name: "search", kind: .function))

        let argDeltas = deltas.filter { if case .toolCallDelta = $0 { return true }; return false }
        #expect(argDeltas.count == 2)
        #expect(argDeltas[0] == .toolCallDelta(index: 0, arguments: #"{"q":"#))
        #expect(argDeltas[1] == .toolCallDelta(index: 0, arguments: #""test"}"#))
    }

    @Test
    func finishedDeltaFromMessageDelta() async throws {
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":42}}"#),
            sseLine(#"{"type":"message_stop"}"#)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let finished = deltas.filter { if case .finished = $0 { return true }; return false }
        #expect(finished.count == 1)
        if case let .finished(usage) = finished[0] {
            #expect(usage?.input == 0)
            #expect(usage?.output == 42)
        } else {
            Issue.record("Expected .finished delta")
        }
    }

    @Test
    func pingIgnored() async throws {
        let lines = [
            sseLine(#"{"type":"ping"}"#),
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":5}}"#),
            sseLine(#"{"type":"message_stop"}"#)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let contentDeltas = deltas.filter { if case .content = $0 { return true }; return false }
        #expect(contentDeltas.count == 1)
    }

    @Test
    func errorEventThrows() async throws {
        let lines = [
            sseLine(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        ]
        do {
            _ = try await collectStreamDeltas(client: makeClient(), lines: lines)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .other(msg) = transport
            else {
                Issue.record("Expected .other, got \(error)")
                return
            }
            #expect(msg.contains("overloaded_error"))
        }
    }

    @Test
    func unknownEventTypesIgnored() async throws {
        let msgStart = #"{"type":"message_start","message":"#
            + #"{"id":"msg_01","type":"message","role":"assistant","#
            + #""content":[],"usage":{"input_tokens":10,"output_tokens":0}}}"#
        let lines = [
            sseLine(msgStart),
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":5}}"#),
            sseLine(#"{"type":"message_stop"}"#)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let contentDeltas = deltas.filter { if case .content = $0 { return true }; return false }
        #expect(contentDeltas.count == 1)
    }

    @Test
    func interleavedThinkingAndToolUseStreaming() async throws {
        let toolBlock = #"{"type":"content_block_start","index":2,"content_block":"#
            + #"{"type":"tool_use","id":"toolu_01","name":"search"}}"#
        let toolDelta = #"{"type":"content_block_delta","index":2,"delta":"#
            + #"{"type":"input_json_delta","partial_json":"{}"}}"#
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig1"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Searching"}}"#),
            sseLine(#"{"type":"content_block_stop","index":1}"#),
            sseLine(toolBlock),
            sseLine(toolDelta),
            sseLine(#"{"type":"content_block_stop","index":2}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":30}}"#),
            sseLine(#"{"type":"message_stop"}"#)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let reasoning = deltas.filter { if case .reasoning = $0 { return true }; return false }
        #expect(reasoning.count == 1)

        let details = deltas.filter { if case .reasoningDetails = $0 { return true }; return false }
        #expect(details.count == 1)

        let content = deltas.filter { if case .content = $0 { return true }; return false }
        #expect(content.count == 1)

        let toolStart = deltas.filter { if case .toolCallStart = $0 { return true }; return false }
        #expect(toolStart.count == 1)
        #expect(toolStart[0] == .toolCallStart(index: 0, id: "toolu_01", name: "search", kind: .function))
    }

    @Test
    func emptyInputToolCallProducesValidJSON() async throws {
        let toolStart = #"{"type":"content_block_start","index":0,"content_block":"#
            + #"{"type":"tool_use","id":"toolu_01","name":"list_items"}}"#
        let emptyDelta = #"{"type":"content_block_delta","index":0,"delta":"#
            + #"{"type":"input_json_delta","partial_json":""}}"#
        let lines = [
            sseLine(toolStart),
            sseLine(emptyDelta),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":5}}"#),
            sseLine(#"{"type":"message_stop"}"#)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let starts = deltas.filter { if case .toolCallStart = $0 { return true }; return false }
        #expect(starts.count == 1)
        #expect(starts[0] == .toolCallStart(index: 0, id: "toolu_01", name: "list_items", kind: .function))

        let argDeltas = deltas.filter { if case .toolCallDelta = $0 { return true }; return false }
        #expect(argDeltas.isEmpty)
    }

    @Test
    func emptyInputToolCallAccumulatesToValidJSON() {
        var accumulator = ToolCallAccumulator(id: "toolu_01", name: "list_items")
        let toolCall = accumulator.toToolCall()
        #expect(toolCall.arguments == "{}")

        accumulator.arguments = ""
        let toolCall2 = accumulator.toToolCall()
        #expect(toolCall2.arguments == "{}")
    }

    @Test
    func multipleToolCallsHaveCorrectIndices() async throws {
        let startA = #"{"type":"content_block_start","index":0,"content_block":"#
            + #"{"type":"tool_use","id":"toolu_a","name":"search"}}"#
        let deltaA = #"{"type":"content_block_delta","index":0,"delta":"#
            + #"{"type":"input_json_delta","partial_json":"{}"}}"#
        let startB = #"{"type":"content_block_start","index":1,"content_block":"#
            + #"{"type":"tool_use","id":"toolu_b","name":"lookup"}}"#
        let deltaB = #"{"type":"content_block_delta","index":1,"delta":"#
            + #"{"type":"input_json_delta","partial_json":"{}"}}"#
        let lines = [
            sseLine(startA),
            sseLine(deltaA),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(startB),
            sseLine(deltaB),
            sseLine(#"{"type":"content_block_stop","index":1}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":20}}"#),
            sseLine(#"{"type":"message_stop"}"#)
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let starts = deltas.filter { if case .toolCallStart = $0 { return true }; return false }
        #expect(starts.count == 2)
        #expect(starts[0] == .toolCallStart(index: 0, id: "toolu_a", name: "search", kind: .function))
        #expect(starts[1] == .toolCallStart(index: 1, id: "toolu_b", name: "lookup", kind: .function))
    }
}

struct AnthropicStreamingInputUsageTests {
    private func makeClient() throws -> AnthropicClient {
        try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
    }

    private func sseLine(_ json: String) -> String {
        "data: \(json)"
    }

    private func collectStreamDeltas(
        client: AnthropicClient,
        lines: [String]
    ) async throws -> [StreamDelta] {
        let allBytes = lines.joined(separator: "\n\n").appending("\n\n")
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()
        for byte in Array(allBytes.utf8) {
            byteContinuation.yield(byte)
        }
        byteContinuation.finish()

        let controlled = ControlledByteStream(stream: byteStream)
        let streamPair = AsyncThrowingStream<StreamDelta, Error>.makeStream()

        try await client.processTestStream(
            byteStream: controlled,
            continuation: streamPair.continuation
        )

        var collected: [StreamDelta] = []
        for try await delta in streamPair.stream {
            collected.append(delta)
        }
        return collected
    }

    @Test
    func streamingMessageStartCapturesInputTokens() async throws {
        let msgStart = #"{"type":"message_start","message":"#
            + #"{"id":"msg_01","type":"message","role":"assistant","#
            + #""content":[],"usage":{"input_tokens":25,"output_tokens":0}}}"#
        let lines = [
            sseLine(msgStart),
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":10}}"#),
            sseLine(#"{"type":"message_stop"}"#),
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let finished = deltas.filter { if case .finished = $0 { return true }; return false }
        #expect(finished.count == 1)
        if case let .finished(usage) = finished[0] {
            #expect(usage?.input == 25)
            #expect(usage?.output == 10)
        } else {
            Issue.record("Expected .finished delta")
        }
    }

    @Test
    func streamingMessageStartCapturesCacheTokens() async throws {
        let msgStart = #"{"type":"message_start","message":"#
            + #"{"id":"msg_01","type":"message","role":"assistant","#
            + #""content":[],"usage":{"input_tokens":100,"output_tokens":0,"#
            + #""cache_creation_input_tokens":2400,"cache_read_input_tokens":500}}}"#
        let lines = [
            sseLine(msgStart),
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":42}}"#),
            sseLine(#"{"type":"message_stop"}"#),
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let finished = deltas.filter { if case .finished = $0 { return true }; return false }
        #expect(finished.count == 1)
        if case let .finished(usage) = finished[0] {
            #expect(usage?.input == 100)
            #expect(usage?.output == 42)
            #expect(usage?.cacheWrite == 2400)
            #expect(usage?.cacheRead == 500)
        } else {
            Issue.record("Expected .finished delta")
        }
    }

    @Test
    func streamingWithoutMessageStartFallsBackToZero() async throws {
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":5}}"#),
            sseLine(#"{"type":"message_stop"}"#),
        ]
        let deltas = try await collectStreamDeltas(client: makeClient(), lines: lines)

        let finished = deltas.filter { if case .finished = $0 { return true }; return false }
        #expect(finished.count == 1)
        if case let .finished(usage) = finished[0] {
            #expect(usage?.input == 0)
            #expect(usage?.output == 5)
            #expect(usage?.cacheRead == nil)
            #expect(usage?.cacheWrite == nil)
        } else {
            Issue.record("Expected .finished delta")
        }
    }
}

struct AnthropicStreamingContinuityTests {
    private func makeClient() throws -> AnthropicClient {
        try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
    }

    private func sseLine(_ json: String) -> String {
        "data: \(json)"
    }

    private func processStreamWithState(
        client: AnthropicClient,
        lines: [String]
    ) async throws -> AnthropicStreamState {
        let allBytes = lines.joined(separator: "\n\n").appending("\n\n")
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()
        for byte in Array(allBytes.utf8) {
            byteContinuation.yield(byte)
        }
        byteContinuation.finish()

        let controlled = ControlledByteStream(stream: byteStream)
        let streamPair = AsyncThrowingStream<StreamDelta, Error>.makeStream()

        let state = try await client.processTestStreamWithState(
            byteStream: controlled,
            continuation: streamPair.continuation
        )

        for try await _ in streamPair.stream {}
        return state
    }

    @Test
    func streamingFinalizationProducesContinuity() async throws {
        let client = try makeClient()
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello world"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":10}}"#),
            sseLine(#"{"type":"message_stop"}"#),
        ]
        let state = try await processStreamWithState(client: client, lines: lines)
        let blocks = try await state.finalizedBlocks()
        #expect(blocks.count == 1)
        let projection = AnthropicTurnProjection(orderedBlocks: blocks)
        #expect(projection.continuity.substrate == .anthropicMessages)
    }

    @Test
    func streamingPreservesInterleavedBlockOrder() async throws {
        let client = try makeClient()
        let toolBlock = #"{"type":"content_block_start","index":2,"content_block":"#
            + #"{"type":"tool_use","id":"toolu_01","name":"search"}}"#
        let toolDelta = #"{"type":"content_block_delta","index":2,"delta":"#
            + #"{"type":"input_json_delta","partial_json":"{\"q\":\"test\"}"}}"#
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan"}}"#),
            sseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig1"}}"#),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#),
            sseLine(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Searching"}}"#),
            sseLine(#"{"type":"content_block_stop","index":1}"#),
            sseLine(toolBlock),
            sseLine(toolDelta),
            sseLine(#"{"type":"content_block_stop","index":2}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":30}}"#),
            sseLine(#"{"type":"message_stop"}"#),
        ]
        let state = try await processStreamWithState(client: client, lines: lines)
        let blocks = try await state.finalizedBlocks()
        #expect(blocks.count == 3)

        func blockType(_ block: JSONValue) -> String? {
            guard case let .object(dict) = block,
                  case let .string(type) = dict["type"] else { return nil }
            return type
        }

        #expect(blockType(blocks[0]) == "thinking")
        #expect(blockType(blocks[1]) == "text")
        #expect(blockType(blocks[2]) == "tool_use")
    }

    @Test
    func blockingAndStreamingProduceSameContinuity() async throws {
        let client = try makeClient()

        let blockingJSON = """
        {
            "id": "msg_parity",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "Let me think", "signature": "sig_1"},
                {"type": "text", "text": "Here is my answer"},
                {"type": "tool_use", "id": "toolu_1", "name": "search",
                 "input": {"q": "test"}}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let blockingMsg = try client.parseResponse(Data(blockingJSON.utf8))

        let toolStart = #"{"type":"content_block_start","index":2,"content_block":"#
            + #"{"type":"tool_use","id":"toolu_1","name":"search"}}"#
        let toolDelta = #"{"type":"content_block_delta","index":2,"delta":"#
            + #"{"type":"input_json_delta","partial_json":"{\"q\":\"test\"}"}}"#
        let thinkDelta = #"{"type":"content_block_delta","index":0,"delta":"#
            + #"{"type":"thinking_delta","thinking":"Let me think"}}"#
        let sigDelta = #"{"type":"content_block_delta","index":0,"delta":"#
            + #"{"type":"signature_delta","signature":"sig_1"}}"#
        let textDelta = #"{"type":"content_block_delta","index":1,"delta":"#
            + #"{"type":"text_delta","text":"Here is my answer"}}"#
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#),
            sseLine(thinkDelta),
            sseLine(sigDelta),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#),
            sseLine(textDelta),
            sseLine(#"{"type":"content_block_stop","index":1}"#),
            sseLine(toolStart),
            sseLine(toolDelta),
            sseLine(#"{"type":"content_block_stop","index":2}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":50}}"#),
            sseLine(#"{"type":"message_stop"}"#),
        ]
        let state = try await processStreamWithState(client: client, lines: lines)
        let streamBlocks = try await state.finalizedBlocks()
        let streamContinuity = AnthropicTurnProjection(orderedBlocks: streamBlocks).continuity

        #expect(blockingMsg.continuity == streamContinuity)
    }

    @Test
    func emptyToolInputParityBetweenBlockingAndStreaming() async throws {
        let client = try makeClient()

        let blockingJSON = """
        {
            "id": "msg_empty",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "tool_use", "id": "toolu_e", "name": "get_time",
                 "input": {}}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 30, "output_tokens": 10}
        }
        """
        let blockingMsg = try client.parseResponse(Data(blockingJSON.utf8))

        let toolStart = #"{"type":"content_block_start","index":0,"content_block":"#
            + #"{"type":"tool_use","id":"toolu_e","name":"get_time"}}"#
        let lines = [
            sseLine(toolStart),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":10}}"#),
            sseLine(#"{"type":"message_stop"}"#),
        ]
        let state = try await processStreamWithState(client: client, lines: lines)
        let streamBlocks = try await state.finalizedBlocks()
        let streamContinuity = AnthropicTurnProjection(orderedBlocks: streamBlocks).continuity

        #expect(blockingMsg.continuity == streamContinuity)
    }
}

extension AnthropicClient {
    func processTestStream(
        byteStream: ControlledByteStream,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        let state = AnthropicStreamState()
        try await processSSEStream(
            bytes: byteStream,
            stallTimeout: nil
        ) { event in
            try await self.handleSSEEvent(
                event, state: state, continuation: continuation
            )
        }
        continuation.finish()
    }

    func processTestStreamWithState(
        byteStream: ControlledByteStream,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws -> AnthropicStreamState {
        let state = AnthropicStreamState()
        try await processSSEStream(
            bytes: byteStream,
            stallTimeout: nil
        ) { event in
            try await self.handleSSEEvent(
                event, state: state, continuation: continuation
            )
        }
        continuation.finish()
        return state
    }
}
