@testable import AgentRunKit
import Foundation
import Testing

struct AnthropicContentBlockEncodingTests {
    private func encodeBlock(_ block: AnthropicContentBlock) throws -> [String: Any] {
        let data = try JSONEncoder().encode(block)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            preconditionFailure("Encoded block is not a JSON object: \(object)")
        }
        return dict
    }

    @Test
    func textBlockWireFormat() throws {
        let json = try encodeBlock(.text("Hello"))

        #expect(json["type"] as? String == "text")
        #expect(json["text"] as? String == "Hello")
        #expect(json.count == 2)
    }

    @Test
    func thinkingBlockWireFormat() throws {
        let json = try encodeBlock(.thinking(thinking: "Let me think", signature: "sig_abc"))

        #expect(json["type"] as? String == "thinking")
        #expect(json["thinking"] as? String == "Let me think")
        #expect(json["signature"] as? String == "sig_abc")
        #expect(json.count == 3)
    }

    @Test
    func toolUseBlockWireFormat() throws {
        let input: JSONValue = .object(["city": .string("NYC")])
        let json = try encodeBlock(.toolUse(id: "toolu_01", name: "get_weather", input: input))

        #expect(json["type"] as? String == "tool_use")
        #expect(json["id"] as? String == "toolu_01")
        #expect(json["name"] as? String == "get_weather")
        let inputDict = json["input"] as? [String: Any]
        #expect(inputDict?["city"] as? String == "NYC")
        #expect(json.count == 4)
    }

    @Test
    func toolResultBlockWireFormat() throws {
        let json = try encodeBlock(.toolResult(toolUseId: "toolu_01", content: "result", isError: false))

        #expect(json["type"] as? String == "tool_result")
        #expect(json["tool_use_id"] as? String == "toolu_01")
        #expect(json["content"] as? String == "result")
        #expect(json["is_error"] == nil)
        #expect(json.count == 3)
    }

    @Test
    func toolResultErrorBlockWireFormat() throws {
        let json = try encodeBlock(.toolResult(toolUseId: "toolu_02", content: "failed", isError: true))

        #expect(json["type"] as? String == "tool_result")
        #expect(json["tool_use_id"] as? String == "toolu_02")
        #expect(json["content"] as? String == "failed")
        #expect(json["is_error"] as? Bool == true)
        #expect(json.count == 4)
    }

    @Test
    func opaqueBlockEncodesObjectRawPayloadWithoutWrapperKeys() throws {
        let raw: JSONValue = .object([
            "type": .string("web_search_tool_result"),
            "tool_use_id": .string("srvtu_01"),
            "content": .array([.object(["url": .string("example.com")])]),
        ])
        let json = try encodeBlock(.opaque(raw))

        #expect(json.count == 3, "opaque encoding must carry exactly the raw payload's keys")
        #expect(json["type"] as? String == "web_search_tool_result")
        #expect(json["tool_use_id"] as? String == "srvtu_01")
        let content = try #require(json["content"] as? [[String: Any]])
        #expect(content.first?["url"] as? String == "example.com")
    }

    @Test
    func opaqueBlockEncodesArrayRawPayload() throws {
        let raw: JSONValue = .array([.string("a"), .int(1), .bool(true)])
        let block = AnthropicContentBlock.opaque(raw)
        let data = try JSONEncoder().encode(block)
        let object = try JSONSerialization.jsonObject(with: data)
        let array = try #require(object as? [Any])
        #expect(array.count == 3)
        #expect(array[0] as? String == "a")
        #expect(array[1] as? Int == 1)
        #expect(array[2] as? Bool == true)
    }

    @Test
    func opaqueBlockEncodesScalarRawPayload() throws {
        let raw: JSONValue = .string("plain")
        let block = AnthropicContentBlock.opaque(raw)
        let data = try JSONEncoder().encode(block)
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        #expect(object as? String == "plain")
    }

    @Test
    func thinkingConfigEnabledWireFormat() throws {
        let config = AnthropicThinkingConfig.enabled(budgetTokens: 8192)
        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = object as? [String: Any]

        #expect(json?["type"] as? String == "enabled")
        #expect(json?["budget_tokens"] as? Int == 8192)
        #expect(json?.count == 2)
    }

    @Test
    func thinkingConfigDisabledWireFormat() throws {
        let config = AnthropicThinkingConfig.disabled
        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = object as? [String: Any]

        #expect(json?["type"] as? String == "disabled")
        #expect(json?.count == 1)
    }

    @Test
    func thinkingConfigAdaptiveWireFormat() throws {
        let config = AnthropicThinkingConfig.adaptive(display: nil)
        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = object as? [String: Any]

        #expect(json?["type"] as? String == "adaptive")
        #expect(json?.count == 1)
    }

    @Test
    func outputConfigWireFormat() throws {
        let config = AnthropicOutputConfig(effort: .max)
        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = object as? [String: Any]

        #expect(json?["effort"] as? String == "max")
        #expect(json?.count == 1)
    }
}

struct AnthropicCacheControlWireFormatTests {
    private func encodeToDict(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            preconditionFailure("Encoded value is not a JSON object: \(object)")
        }
        return dict
    }

    @Test
    func systemBlockWithoutCacheControl() throws {
        let block = AnthropicSystemBlock(text: "Be helpful")
        let json = try encodeToDict(block)

        #expect(json["type"] as? String == "text")
        #expect(json["text"] as? String == "Be helpful")
        #expect(json["cache_control"] == nil)
        #expect(json.count == 2)
    }

    @Test
    func systemBlockCacheControlWireFormat() throws {
        var block = AnthropicSystemBlock(text: "Be helpful")
        block.cacheControl = CacheControl()
        let json = try encodeToDict(block)

        #expect(json["type"] as? String == "text")
        #expect(json["text"] as? String == "Be helpful")
        let cacheControl = json["cache_control"] as? [String: Any]
        #expect(cacheControl?["type"] as? String == "ephemeral")
        #expect(json.count == 3)
    }

    @Test
    func toolDefinitionCacheControlWireFormat() throws {
        let def = ToolDefinition(
            name: "search", description: "Search",
            parametersSchema: .object(properties: [:], required: [])
        )
        var toolDef = try AnthropicToolDefinition(def)
        toolDef.cacheControl = CacheControl()
        let json = try encodeToDict(toolDef)

        #expect(json.count == 4)
        #expect(json["name"] as? String == "search")
        #expect(json["description"] as? String == "Search")
        #expect(json["input_schema"] != nil)
        let cacheControl = json["cache_control"] as? [String: Any]
        #expect(cacheControl?["type"] as? String == "ephemeral")
    }

    @Test
    func toolDefinitionWithoutCacheControl() throws {
        let def = ToolDefinition(
            name: "search", description: "Search",
            parametersSchema: .object(properties: [:], required: [])
        )
        let toolDef = try AnthropicToolDefinition(def)
        let json = try encodeToDict(toolDef)

        #expect(json["cache_control"] == nil)
    }
}

struct AnthropicMessageContentEncodingTests {
    @Test
    func blocksWithCacheControlEncodeAsBlockArray() throws {
        let content = AnthropicMessageContent.blocks([
            .text("Hi", cacheControl: CacheControl())
        ])
        let data = try JSONEncoder().encode(content)
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(array.count == 1)
        let block = array[0]
        #expect(block["type"] as? String == "text")
        #expect(block["text"] as? String == "Hi")
        let cacheControl = try #require(block["cache_control"] as? [String: Any])
        #expect(cacheControl["type"] as? String == "ephemeral")
    }
}

struct AnthropicErrorHandlingTests {
    @Test
    func malformedResponseThrowsDecodingError() throws {
        let client = try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
        let garbage = Data("not json at all".utf8)

        #expect(throws: AgentError.self) {
            _ = try client.parseResponse(garbage)
        }
    }

    @Test
    func unknownContentBlockDecodesAsOpaque() throws {
        let json = """
        {
            "id": "msg_001",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Hello"},
                {"type": "web_search_tool_result", "content": [{"url": "example.com"}]}
            ],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        let client = try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")

        let message = try client.parseResponse(Data(json.utf8))

        #expect(message.content == "Hello")
        #expect(message.toolCalls.isEmpty)
        let continuityPayload = message.continuity?.payload
        guard case let .object(payload) = continuityPayload,
              case let .array(blocks) = payload["content"]
        else {
            Issue.record("expected continuity content array")
            return
        }
        #expect(blocks.count == 2)

        guard case let .object(opaqueBlock) = blocks[1],
              case let .string(type) = opaqueBlock["type"]
        else {
            Issue.record("expected opaque block to preserve type")
            return
        }
        #expect(type == "web_search_tool_result")
    }

    @Test
    func opaqueContinuityBlockReplaysWithoutThrowing() throws {
        let continuity = AssistantContinuity(
            substrate: .anthropicMessages,
            payload: .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Hello"),
                    ]),
                    .object([
                        "type": .string("web_search_tool_result"),
                        "content": .array([
                            .object(["url": .string("example.com")])
                        ]),
                    ]),
                ])
            ])
        )
        let blocks = try AnthropicTurnProjection.replayBlocks(from: continuity)
        #expect(blocks.count == 2)
        let data = try JSONEncoder().encode(blocks[1])
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "web_search_tool_result")
    }

    @Test
    func malformedKnownBlockStillThrows() throws {
        let json = """
        {
            "id": "msg_001",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "tool_use", "id": "call_1"}],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        let client = try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")

        #expect(throws: AgentError.self) {
            _ = try client.parseResponse(Data(json.utf8))
        }
    }
}
