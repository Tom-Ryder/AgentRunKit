@testable import AgentRunKit
import Foundation
import Testing

// MARK: - .unknown family guards

struct UnknownFamilyGuardTests {
    @Test
    func anthropicUnknownFamily_rejectsActiveReasoning() {
        #expect(throws: AgentError.self) {
            _ = try AnthropicClient(
                apiKey: "test-key",
                model: "claude-opus-4-9",
                reasoningConfig: .high
            )
        }
    }

    @Test
    func anthropicUnknownFamily_allowsNoReasoning() throws {
        _ = try AnthropicClient(apiKey: "test-key", model: "claude-opus-4-9")
    }

    @Test
    func geminiUnknownFamily_throwsWhenBuildingThinkingConfig() throws {
        let client = GeminiClient(
            apiKey: "k", model: "gemini-4-ultra",
            reasoningConfig: .high
        )
        #expect(throws: AgentError.self) {
            _ = try client.buildThinkingConfig()
        }
    }

    @Test
    func geminiUnknownFamily_allowsExplicitBudget() throws {
        let client = GeminiClient(
            apiKey: "k", model: "gemini-4-ultra",
            reasoningConfig: .budget(1024)
        )
        let config = try client.buildThinkingConfig()
        #expect(config?.thinkingBudget == 1024)
    }
}

// MARK: - Anthropic adaptive.display

private struct AdaptiveWeather: Codable, SchemaProviding, Equatable {
    let city: String
}

struct AnthropicAdaptiveDisplayTests {
    private func encodeRequest(_ request: AnthropicRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func adaptiveWithOmittedDisplay_emitsDisplayKey() throws {
        let client = try AnthropicClient(
            apiKey: "k",
            model: "claude-sonnet-4-6",
            reasoningConfig: .high,
            anthropicReasoning: .adaptive(display: .omitted)
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] as? String == "omitted")
    }

    @Test
    func adaptiveWithDefaultDisplay_omitsDisplayKey() throws {
        let client = try AnthropicClient(
            apiKey: "k",
            model: "claude-sonnet-4-6",
            reasoningConfig: .high,
            anthropicReasoning: .adaptive
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] == nil)
    }

    @Test
    func adaptiveSummarized_emitsSummarized() throws {
        let client = try AnthropicClient(
            apiKey: "k",
            model: "claude-sonnet-4-6",
            reasoningConfig: .high,
            anthropicReasoning: .adaptive(display: .summarized)
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["display"] as? String == "summarized")
    }
}

// MARK: - Anthropic CacheControl.ttl

struct AnthropicCacheControlTTLTests {
    private func encodeRequest(_ request: AnthropicRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func defaultTTL_omitsTTLKey() throws {
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-sonnet-4-6",
            cachingEnabled: true
        )
        let request = try client.buildRequest(
            messages: [.system("Be helpful"), .user("Hi")],
            tools: []
        )
        let json = try encodeRequest(request)
        let system = try #require(json["system"] as? [[String: Any]])
        let cacheControl = try #require(system.last?["cache_control"] as? [String: Any])
        #expect(cacheControl["type"] as? String == "ephemeral")
        #expect(cacheControl["ttl"] == nil)
    }

    @Test
    func oneHourTTL_emitsOnSystemBlock() throws {
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-sonnet-4-6",
            cachingEnabled: true,
            cacheControlTTL: .oneHour
        )
        let request = try client.buildRequest(
            messages: [.system("Be helpful"), .user("Hi")],
            tools: []
        )
        let json = try encodeRequest(request)
        let system = try #require(json["system"] as? [[String: Any]])
        let cacheControl = try #require(system.last?["cache_control"] as? [String: Any])
        #expect(cacheControl["ttl"] as? String == "1h")
    }

    @Test
    func fiveMinutesTTL_emitsOnToolDef() throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "",
            parametersSchema: .object(properties: [:], required: [])
        )
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-sonnet-4-6",
            cachingEnabled: true,
            cacheControlTTL: .fiveMinutes
        )
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [tool]
        )
        let json = try encodeRequest(request)
        let tools = try #require(json["tools"] as? [[String: Any]])
        let cacheControl = try #require(tools.last?["cache_control"] as? [String: Any])
        #expect(cacheControl["ttl"] as? String == "5m")
    }

    @Test
    func ttlEmittedOnSecondToLastUserMessage() throws {
        let client = try AnthropicClient(
            apiKey: "k", model: "claude-sonnet-4-6",
            cachingEnabled: true,
            cacheControlTTL: .oneHour
        )
        let messages: [ChatMessage] = [
            .user("First"),
            .assistant(AssistantMessage(content: "ok")),
            .user("Second"),
        ]
        let request = try client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)
        let msgs = try #require(json["messages"] as? [[String: Any]])
        let firstUser = try #require(msgs.first?["content"] as? [[String: Any]])
        let cacheControl = try #require(firstUser.first?["cache_control"] as? [String: Any])
        #expect(cacheControl["ttl"] as? String == "1h")
    }
}

// MARK: - OpenAI Chat tool-call type round-trip

struct OpenAIChatToolCallTypeRoundTripTests {
    @Test
    func customToolCallDecode_preservesType() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "tool_calls": [{
                        "id": "call_cust",
                        "type": "custom",
                        "custom": {"name": "grammar_query", "input": "SELECT 1"}
                    }]
                }
            }]
        }
        """
        let message = try client.parseResponse(Data(json.utf8))
        let call = try #require(message.toolCalls.first)
        #expect(call.kind == .custom)
        #expect(call.name == "grammar_query")
        #expect(call.arguments == "SELECT 1")
    }

    @Test
    func functionToolCallDecode_preservesFunctionType() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "tool_calls": [{
                        "id": "call_fn",
                        "type": "function",
                        "function": {"name": "add", "arguments": "{}"}
                    }]
                }
            }]
        }
        """
        let message = try client.parseResponse(Data(json.utf8))
        let call = try #require(message.toolCalls.first)
        #expect(call.kind == .function)
    }

    @Test
    func unknownResponseToolType_throwsFeatureUnsupported() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "tool_calls": [{
                        "id": "call_mcp",
                        "type": "mcp"
                    }]
                }
            }]
        }
        """
        #expect(throws: AgentError.self) {
            _ = try client.parseResponse(Data(json.utf8))
        }
    }

    @Test
    func replayCustomToolCall_emitsCustomShape() throws {
        let call = ToolCall(id: "call_1", name: "grammar_query", arguments: "SELECT 1", kind: .custom)
        let message = AssistantMessage(content: "", toolCalls: [call])
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Prompt"), .assistant(message)],
            tools: []
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages.last { ($0["role"] as? String) == "assistant" })
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let rawCall = try #require(toolCalls.first)
        #expect(rawCall["type"] as? String == "custom")
        let custom = try #require(rawCall["custom"] as? [String: Any])
        #expect(custom["name"] as? String == "grammar_query")
        #expect(custom["input"] as? String == "SELECT 1")
        #expect(rawCall["function"] == nil)
    }

    @Test
    func replayFunctionToolCall_emitsFunctionShape() throws {
        let call = ToolCall(id: "call_2", name: "add", arguments: "{\"a\":1}")
        let message = AssistantMessage(content: "", toolCalls: [call])
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Prompt"), .assistant(message)],
            tools: []
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages.last { ($0["role"] as? String) == "assistant" })
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let rawCall = try #require(toolCalls.first)
        #expect(rawCall["type"] as? String == "function")
        #expect(rawCall["function"] != nil)
        #expect(rawCall["custom"] == nil)
    }

    @Test
    func decodeUnknownToolKindFromWire_throws() {
        let raw = Data(#"{"id":"call","name":"x","arguments":"{}","type":"mcp"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ToolCall.self, from: raw)
        }
    }
}

// MARK: - Anthropic streaming opaque delta symmetry

struct AnthropicOpaqueStreamingDeltaTests {
    @Test
    func opaqueStartPlusDelta_preservesBoth() async throws {
        let state = AnthropicStreamState()
        let startRaw: JSONValue = .object([
            "type": .string("future_block"),
            "id": .string("blk_1"),
        ])
        let deltaRaw: JSONValue = .object([
            "type": .string("future_delta"),
            "partial": .string("data"),
        ])

        await state.setBlockType(0, .opaque)
        await state.setOpaqueBlock(0, raw: startRaw)
        await state.appendOpaqueDelta(0, raw: deltaRaw)

        let blocks = try await state.finalizedBlocks()
        #expect(blocks.count == 1)
        #expect(blocks[0] == startRaw)
        #expect(await state.supportsReplayContinuity() == false)
    }

    @Test
    func opaqueStartWithoutDelta_preservesStartAsIs() async throws {
        let state = AnthropicStreamState()
        let startRaw: JSONValue = .object([
            "type": .string("future_block"),
        ])

        await state.setBlockType(0, .opaque)
        await state.setOpaqueBlock(0, raw: startRaw)

        let blocks = try await state.finalizedBlocks()
        #expect(blocks.count == 1)
        #expect(blocks[0] == startRaw)
    }
}
