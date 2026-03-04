import Foundation
import Testing

@testable import AgentRunKit

@Suite
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
}

@Suite
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
        var toolDef = AnthropicToolDefinition(def)
        toolDef.cacheControl = CacheControl()
        let json = try encodeToDict(toolDef)

        #expect(json["name"] as? String == "search")
        #expect(json["description"] as? String == "Search")
        let cacheControl = json["cache_control"] as? [String: Any]
        #expect(cacheControl?["type"] as? String == "ephemeral")
    }

    @Test
    func toolDefinitionWithoutCacheControl() throws {
        let def = ToolDefinition(
            name: "search", description: "Search",
            parametersSchema: .object(properties: [:], required: [])
        )
        let toolDef = AnthropicToolDefinition(def)
        let json = try encodeToDict(toolDef)

        #expect(json["cache_control"] == nil)
    }
}

@Suite
struct AnthropicErrorHandlingTests {
    @Test
    func malformedResponseThrowsDecodingError() {
        let client = AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
        let garbage = Data("not json at all".utf8)

        #expect(throws: AgentError.self) {
            _ = try client.parseResponse(garbage)
        }
    }

    @Test
    func unknownContentBlockTypeThrows() {
        let json = """
        {
            "id": "msg_001",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "unknown_block", "data": "something"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        let client = AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")

        #expect(throws: AgentError.self) {
            _ = try client.parseResponse(Data(json.utf8))
        }
    }
}
