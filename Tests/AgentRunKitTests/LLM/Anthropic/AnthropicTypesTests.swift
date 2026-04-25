@testable import AgentRunKit
import Foundation
import Testing

struct AnthropicResponseParsingTests {
    private func makeClient() throws -> AnthropicClient {
        try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
    }

    @Test
    func textResponse() throws {
        let json = """
        {
            "id": "msg_001",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Hello there!"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "Hello there!")
        #expect(msg.toolCalls.isEmpty)
        #expect(msg.tokenUsage?.input == 100)
        #expect(msg.tokenUsage?.output == 50)
    }

    @Test
    func toolUseResponse() throws {
        let json = """
        {
            "id": "msg_002",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Let me check."},
                {"type": "tool_use", "id": "toolu_01", "name": "get_weather",
                 "input": {"city": "NYC"}}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 50, "output_tokens": 30}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "Let me check.")
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "toolu_01")
        #expect(msg.toolCalls[0].name == "get_weather")
        #expect(msg.toolCalls[0].arguments.contains("NYC"))
    }

    @Test
    func thinkingResponse() throws {
        let json = """
        {
            "id": "msg_003",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "Let me reason...", "signature": "sig123"},
                {"type": "text", "text": "The answer is 42."}
            ],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 100, "output_tokens": 200}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "The answer is 42.")
        #expect(msg.reasoning?.content == "Let me reason...")
        #expect(msg.reasoningDetails?.count == 1)
        if case let .object(dict) = msg.reasoningDetails?[0] {
            #expect(dict["type"] == .string("thinking"))
            #expect(dict["thinking"] == .string("Let me reason..."))
            #expect(dict["signature"] == .string("sig123"))
        } else {
            Issue.record("Expected object in reasoning details")
        }
    }

    @Test
    func interleavedThinkingAndToolUse() throws {
        let json = """
        {
            "id": "msg_004",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "Think first", "signature": "s1"},
                {"type": "text", "text": "Checking."},
                {"type": "tool_use", "id": "toolu_02", "name": "search",
                 "input": {"q": "test"}},
                {"type": "thinking", "thinking": "Think again", "signature": "s2"},
                {"type": "text", "text": "More text."}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 80, "output_tokens": 120}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "Checking.More text.")
        #expect(msg.toolCalls.count == 1)
        #expect(msg.reasoning?.content == "Think first\nThink again")
        #expect(msg.reasoningDetails?.count == 2)
    }

    @Test
    func errorResponse() throws {
        let json = """
        {
            "type": "error",
            "error": {"type": "invalid_request_error", "message": "Bad input"}
        }
        """
        do {
            _ = try makeClient().parseResponse(Data(json.utf8))
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .other(msg) = transport
            else {
                Issue.record("Expected .other, got \(error)")
                return
            }
            #expect(msg.contains("invalid_request_error"))
            #expect(msg.contains("Bad input"))
        }
    }

    @Test
    func usageMapping() throws {
        let json = """
        {
            "id": "msg_005",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Hi"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 200, "output_tokens": 100}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.tokenUsage == TokenUsage(input: 200, output: 100))
    }

    @Test
    func emptyContentParsesToEmptyString() throws {
        let json = """
        {
            "id": "msg_006",
            "type": "message",
            "role": "assistant",
            "content": [],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 0}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.content == "")
        #expect(msg.toolCalls.isEmpty)
        #expect(msg.continuity == nil)
    }

    @Test
    func emptyContentReplaysSafely() throws {
        let json = """
        {
            "id": "msg_empty_rt",
            "type": "message",
            "role": "assistant",
            "content": [],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 0}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(msg)])
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        #expect(blocks.count == 1)
        if case let .text(text, _) = blocks[0] {
            #expect(text == "")
        } else {
            Issue.record("Expected empty text block")
        }
    }

    @Test
    func multipleToolUseParsesAll() throws {
        let json = """
        {
            "id": "msg_007",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "tool_use", "id": "toolu_a", "name": "search",
                 "input": {"q": "first"}},
                {"type": "tool_use", "id": "toolu_b", "name": "lookup",
                 "input": {"id": 42}}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 50, "output_tokens": 30}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.toolCalls.count == 2)
        #expect(msg.toolCalls[0].id == "toolu_a")
        #expect(msg.toolCalls[1].id == "toolu_b")
    }

    @Test
    func toolCallArgumentsRoundTripAsJSONObject() throws {
        let json = """
        {
            "id": "msg_008",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "tool_use", "id": "toolu_rt", "name": "get_weather",
                 "input": {"city": "NYC", "units": "celsius"}}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 40, "output_tokens": 20}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "toolu_rt")
        #expect(msg.toolCalls[0].name == "get_weather")

        let parsedArgs = try JSONDecoder().decode(
            [String: String].self, from: Data(msg.toolCalls[0].arguments.utf8)
        )
        #expect(parsedArgs["city"] == "NYC")
        #expect(parsedArgs["units"] == "celsius")

        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(msg)])
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        let toolBlock = blocks.first { if case .toolUse = $0 { return true }; return false }
        guard case let .some(.toolUse(id, name, input, _)) = toolBlock else {
            Issue.record("Expected toolUse block")
            return
        }
        #expect(id == "toolu_rt")
        #expect(name == "get_weather")
        guard case let .object(inputDict) = input else {
            Issue.record("Expected input to be a JSON object, not a string")
            return
        }
        #expect(inputDict["city"] == JSONValue.string("NYC"))
        #expect(inputDict["units"] == JSONValue.string("celsius"))
    }
}

struct AnthropicContinuityTests {
    private func makeClient() throws -> AnthropicClient {
        try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
    }

    @Test
    func blockingParseProducesContinuity() throws {
        let json = """
        {
            "id": "msg_001",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Hello"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.continuity?.substrate == .anthropicMessages)
        guard case let .object(payload) = msg.continuity?.payload,
              case let .array(blocks) = payload["content"] else {
            Issue.record("Expected continuity with content array")
            return
        }
        #expect(blocks.count == 1)
        if case let .object(dict) = blocks[0] {
            #expect(dict["type"] == .string("text"))
            #expect(dict["text"] == .string("Hello"))
        } else {
            Issue.record("Expected object block")
        }
    }

    @Test
    func continuityPreservesInterleavedBlockOrder() throws {
        let json = """
        {
            "id": "msg_002",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "Think first", "signature": "s1"},
                {"type": "text", "text": "Checking."},
                {"type": "tool_use", "id": "toolu_01", "name": "search",
                 "input": {"q": "test"}},
                {"type": "thinking", "thinking": "Think again", "signature": "s2"},
                {"type": "text", "text": "More text."}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 80, "output_tokens": 120}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        guard case let .object(payload) = msg.continuity?.payload,
              case let .array(blocks) = payload["content"] else {
            Issue.record("Expected continuity with content array")
            return
        }
        #expect(blocks.count == 5)

        func blockType(_ block: JSONValue) -> String? {
            guard case let .object(dict) = block,
                  case let .string(type) = dict["type"] else { return nil }
            return type
        }

        #expect(blockType(blocks[0]) == "thinking")
        #expect(blockType(blocks[1]) == "text")
        #expect(blockType(blocks[2]) == "tool_use")
        #expect(blockType(blocks[3]) == "thinking")
        #expect(blockType(blocks[4]) == "text")
    }

    @Test
    func replayPrefersAnthropicContinuity() throws {
        let continuity = AssistantContinuity(
            substrate: .anthropicMessages,
            payload: .object(["content": .array([
                .object(["type": .string("text"), "text": .string("Original text")]),
                .object([
                    "type": .string("thinking"),
                    "thinking": .string("Deep thought"),
                    "signature": .string("sig_abc"),
                ]),
            ])])
        )
        let msg = AssistantMessage(
            content: "Reconstructed text",
            reasoning: ReasoningContent(content: "Reconstructed reasoning", signature: "sig_abc"),
            continuity: continuity
        )

        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(msg)])
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }

        #expect(blocks.count == 2)
        if case let .text(text, _) = blocks[0] {
            #expect(text == "Original text")
        } else {
            Issue.record("Expected text block at index 0")
        }
        if case let .thinking(thinking, signature) = blocks[1] {
            #expect(thinking == "Deep thought")
            #expect(signature == "sig_abc")
        } else {
            Issue.record("Expected thinking block at index 1")
        }
    }

    @Test
    func semanticFallbackWhenNoContinuity() throws {
        let msg = AssistantMessage(
            content: "Answer",
            reasoning: ReasoningContent(content: "reasoning", signature: "sig_xyz")
        )
        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(msg)])
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        #expect(blocks.count == 2)
        if case .thinking = blocks[0] {} else {
            Issue.record("Expected thinking block first in semantic fallback")
        }
        if case .text = blocks[1] {} else {
            Issue.record("Expected text block second in semantic fallback")
        }
    }

    @Test
    func semanticFallbackForForeignSubstrate() throws {
        let foreignContinuity = AssistantContinuity(
            substrate: .responses,
            payload: .object(["output": .array([])])
        )
        let msg = AssistantMessage(content: "Answer", continuity: foreignContinuity)
        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(msg)])
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        #expect(blocks.count == 1)
        if case let .text(text, _) = blocks[0] {
            #expect(text == "Answer")
        } else {
            Issue.record("Expected text block")
        }
    }

    @Test
    func malformedContinuityThrows() throws {
        let malformedContinuity = AssistantContinuity(
            substrate: .anthropicMessages,
            payload: .object(["wrong_key": .string("not a content array")])
        )
        let msg = AssistantMessage(content: "Fallback text", continuity: malformedContinuity)
        #expect(throws: AgentError.self) {
            _ = try AnthropicMessageMapper.mapMessages([.assistant(msg)])
        }
    }

    @Test
    func interleavedOrderSurvivesParseAndReplay() throws {
        let json = """
        {
            "id": "msg_rt",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "Plan A", "signature": "sig_a"},
                {"type": "text", "text": "Step 1"},
                {"type": "tool_use", "id": "toolu_01", "name": "search",
                 "input": {"q": "test"}},
                {"type": "thinking", "thinking": "Plan B", "signature": "sig_b"},
                {"type": "text", "text": "Step 2"}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 100, "output_tokens": 200}
        }
        """
        let parsed = try makeClient().parseResponse(Data(json.utf8))

        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(parsed)])
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }

        #expect(blocks.count == 5)
        if case let .thinking(thinking, signature) = blocks[0] {
            #expect(thinking == "Plan A")
            #expect(signature == "sig_a")
        } else {
            Issue.record("Expected thinking at 0")
        }
        if case let .text(text, _) = blocks[1] {
            #expect(text == "Step 1")
        } else {
            Issue.record("Expected text at 1")
        }
        if case let .toolUse(id, name, _, _) = blocks[2] {
            #expect(id == "toolu_01")
            #expect(name == "search")
        } else {
            Issue.record("Expected tool_use at 2")
        }
        if case let .thinking(thinking, signature) = blocks[3] {
            #expect(thinking == "Plan B")
            #expect(signature == "sig_b")
        } else {
            Issue.record("Expected thinking at 3")
        }
        if case let .text(text, _) = blocks[4] {
            #expect(text == "Step 2")
        } else {
            Issue.record("Expected text at 4")
        }
    }

    @Test
    func continuityIsNotInventedByHistoryMutation() throws {
        let msg = AssistantMessage(content: "No continuity")
        #expect(msg.continuity == nil)
        let (_, mapped) = try AnthropicMessageMapper.mapMessages([
            .user("Hello"),
            .assistant(msg),
        ])
        #expect(mapped.count == 2)
    }

    @Test
    func toolUseOnlyResponseRoundTrips() throws {
        let json = """
        {
            "id": "msg_tools",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "tool_use", "id": "toolu_a", "name": "search",
                 "input": {"q": "first"}},
                {"type": "tool_use", "id": "toolu_b", "name": "lookup",
                 "input": {"id": 42}}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 50, "output_tokens": 30}
        }
        """
        let client = try makeClient()
        let parsed = try client.parseResponse(Data(json.utf8))
        #expect(parsed.continuity?.substrate == .anthropicMessages)
        #expect(parsed.content == "")
        #expect(parsed.toolCalls.count == 2)

        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(parsed)])
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        #expect(blocks.count == 2)
        if case let .toolUse(id, name, _, _) = blocks[0] {
            #expect(id == "toolu_a")
            #expect(name == "search")
        } else {
            Issue.record("Expected tool_use at 0")
        }
        if case let .toolUse(id, name, _, _) = blocks[1] {
            #expect(id == "toolu_b")
            #expect(name == "lookup")
        } else {
            Issue.record("Expected tool_use at 1")
        }
    }

    @Test
    func emptyToolInputRoundTrips() throws {
        let json = """
        {
            "id": "msg_empty_input",
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
        let client = try makeClient()
        let parsed = try client.parseResponse(Data(json.utf8))

        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(parsed)])
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        #expect(blocks.count == 1)
        if case let .toolUse(id, name, input, _) = blocks[0] {
            #expect(id == "toolu_e")
            #expect(name == "get_time")
            #expect(input == .object([:]))
        } else {
            Issue.record("Expected tool_use block")
        }
    }
}

struct AnthropicCacheUsageParsingTests {
    private func makeClient() throws -> AnthropicClient {
        try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
    }

    @Test
    func cacheUsageParsedFromResponse() throws {
        let json = """
        {
            "id": "msg_cache",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Hi"}],
            "stop_reason": "end_turn",
            "usage": {
                "input_tokens": 2500,
                "output_tokens": 100,
                "cache_creation_input_tokens": 2400,
                "cache_read_input_tokens": 0
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.tokenUsage?.input == 2500)
        #expect(msg.tokenUsage?.output == 100)
        #expect(msg.tokenUsage?.cacheWrite == 2400)
        #expect(msg.tokenUsage?.cacheRead == 0)
    }

    @Test
    func cacheUsageAbsentParsesAsNil() throws {
        let json = """
        {
            "id": "msg_nocache",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Hi"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8))
        #expect(msg.tokenUsage?.cacheRead == nil)
        #expect(msg.tokenUsage?.cacheWrite == nil)
    }

    @Test
    func tokenUsageAdditionWithCacheFields() {
        let lhs = TokenUsage(input: 100, output: 50, cacheRead: 10, cacheWrite: 20)
        let rhs = TokenUsage(input: 200, output: 100, cacheRead: 30, cacheWrite: nil)
        let sum = lhs + rhs
        #expect(sum.input == 300)
        #expect(sum.output == 150)
        #expect(sum.cacheRead == 40)
        #expect(sum.cacheWrite == 20)

        let noCacheLhs = TokenUsage(input: 50, output: 25)
        let noCacheRhs = TokenUsage(input: 50, output: 25)
        #expect((noCacheLhs + noCacheRhs).cacheRead == nil)
        #expect((noCacheLhs + noCacheRhs).cacheWrite == nil)
    }
}

struct AnthropicMessageTranslationTests {
    @Test
    func toolResultsMergedIntoSingleUserMessage() throws {
        let messages: [ChatMessage] = [
            .tool(id: "call_1", name: "search", content: "result1"),
            .tool(id: "call_2", name: "lookup", content: "result2")
        ]
        let (_, mapped) = try AnthropicMessageMapper.mapMessages(messages)

        #expect(mapped.count == 1)
        #expect(mapped[0].role == .user)
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        #expect(blocks.count == 2)
        if case let .toolResult(id1, content1, isError1, _) = blocks[0] {
            #expect(id1 == "call_1")
            #expect(content1 == "result1")
            #expect(!isError1)
        } else {
            Issue.record("Expected toolResult block at index 0")
        }
        if case let .toolResult(id2, content2, isError2, _) = blocks[1] {
            #expect(id2 == "call_2")
            #expect(content2 == "result2")
            #expect(!isError2)
        } else {
            Issue.record("Expected toolResult block at index 1")
        }
    }

    @Test
    func assistantWithReasoningDetailsRoundTrips() throws {
        let details: [JSONValue] = [
            .object([
                "type": .string("thinking"),
                "thinking": .string("reasoning text"),
                "signature": .string("sig_abc")
            ])
        ]
        let msg = AssistantMessage(content: "Answer", reasoningDetails: details)
        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(msg)])

        #expect(mapped.count == 1)
        #expect(mapped[0].role == .assistant)
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        #expect(blocks.count == 2)
        if case let .thinking(thinking, signature) = blocks[0] {
            #expect(thinking == "reasoning text")
            #expect(signature == "sig_abc")
        } else {
            Issue.record("Expected thinking block at index 0")
        }
        if case let .text(text, _) = blocks[1] {
            #expect(text == "Answer")
        } else {
            Issue.record("Expected text block at index 1")
        }
    }

    @Test
    func assistantFallbackToReasoningContent() throws {
        let reasoning = ReasoningContent(content: "thinking", signature: "sig_xyz")
        let msg = AssistantMessage(content: "Answer", reasoning: reasoning)
        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(msg)])

        #expect(mapped[0].role == .assistant)
        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        #expect(blocks.count == 2)
        if case let .thinking(thinking, signature) = blocks[0] {
            #expect(thinking == "thinking")
            #expect(signature == "sig_xyz")
        } else {
            Issue.record("Expected thinking block at index 0")
        }
        if case let .text(text, _) = blocks[1] {
            #expect(text == "Answer")
        } else {
            Issue.record("Expected text block at index 1")
        }
    }

    @Test
    func reasoningWithoutSignatureOmitted() throws {
        let reasoning = ReasoningContent(content: "thinking")
        let msg = AssistantMessage(content: "Answer", reasoning: reasoning)
        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(msg)])

        guard case let .blocks(blocks) = mapped[0].content else {
            Issue.record("Expected blocks content")
            return
        }
        #expect(blocks.count == 1)
        if case let .text(text, _) = blocks[0] {
            #expect(text == "Answer")
        } else {
            Issue.record("Expected text block, got \(blocks[0])")
        }
    }

    @Test
    func imageURLMultimodalThrowsFeatureUnsupported() {
        #expect(throws: AgentError.self) {
            _ = try AnthropicMessageMapper.mapMessages([
                .userMultimodal([.text("Hi"), .imageURL("https://example.com/img.png")])
            ])
        }
    }

    @Test
    func mixedConversation() throws {
        let toolCall = ToolCall(id: "call_1", name: "search", arguments: "{\"q\":\"test\"}")
        let messages: [ChatMessage] = [
            .system("Be helpful"),
            .user("Search for test"),
            .assistant(AssistantMessage(content: "", toolCalls: [toolCall])),
            .tool(id: "call_1", name: "search", content: "found it")
        ]
        let (system, mapped) = try AnthropicMessageMapper.mapMessages(messages)

        #expect(system?.count == 1)
        #expect(mapped.count == 3)
        #expect(mapped[0].role == .user)
        #expect(mapped[1].role == .assistant)
        #expect(mapped[2].role == .user)
    }

    @Test
    func emptyAssistantGetsEmptyTextBlock() throws {
        let msg = AssistantMessage(content: "")
        let (_, mapped) = try AnthropicMessageMapper.mapMessages([.assistant(msg)])

        if case let .blocks(blocks) = mapped[0].content {
            #expect(blocks.count == 1)
            if case let .text(text, _) = blocks[0] {
                #expect(text == "")
            } else {
                Issue.record("Expected text block")
            }
        } else {
            Issue.record("Expected blocks content")
        }
    }
}
