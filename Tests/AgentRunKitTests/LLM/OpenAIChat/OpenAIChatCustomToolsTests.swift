@testable import AgentRunKit
import Foundation
import Testing

struct OpenAIChatCustomToolDecodeTests {
    private let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")

    @Test
    func customToolCallDecodes_fromNonStream() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [{
                        "id": "call_custom1",
                        "type": "custom",
                        "custom": {"name": "grammar_query", "input": "SELECT * FROM ..."}
                    }]
                },
                "finish_reason": "tool_calls"
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5}
        }
        """
        let message = try client.parseResponse(Data(json.utf8))

        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls[0].id == "call_custom1")
        #expect(message.toolCalls[0].name == "grammar_query")
        #expect(message.toolCalls[0].arguments == "SELECT * FROM ...")
        #expect(message.toolCalls[0].kind == .custom)
    }

    @Test
    func functionToolCallStillDecodes() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [{
                        "id": "call_fn1",
                        "type": "function",
                        "function": {"name": "get_weather", "arguments": "{\\"city\\":\\"NYC\\"}"}
                    }]
                },
                "finish_reason": "tool_calls"
            }]
        }
        """
        let message = try client.parseResponse(Data(json.utf8))
        #expect(message.toolCalls[0].name == "get_weather")
        #expect(message.toolCalls[0].arguments == #"{"city":"NYC"}"#)
        #expect(message.toolCalls[0].kind == .function)
    }
}

struct OpenAIChatStrictSchemaTests {
    private let weatherTool = ToolDefinition(
        name: "get_weather",
        description: "Get the weather",
        parametersSchema: .object(properties: ["city": .string()], required: ["city"]),
        strict: true
    )

    private func toolsJSON(for client: OpenAIClient) throws -> [[String: Any]] {
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [weatherTool])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["tools"] as? [[String: Any]]) ?? []
    }

    @Test
    func firstPartyEmitsStrict() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let tools = try toolsJSON(for: client)
        let function = tools[0]["function"] as? [String: Any]
        #expect(function?["strict"] as? Bool == true)
    }

    @Test
    func compatibleProfileRejectsStrict() throws {
        let client = OpenAIClient.proxy(baseURL: OpenAIClient.groqBaseURL)
        #expect(throws: AgentError.self) {
            _ = try toolsJSON(for: client)
        }
    }

    @Test
    func openRouterProfileRejectsStrict() throws {
        let client = OpenAIClient.openRouter(apiKey: "k", model: "anthropic/claude-sonnet-4.6")
        #expect(throws: AgentError.self) {
            _ = try toolsJSON(for: client)
        }
    }

    @Test
    func nonStrictToolOnFirstParty_omitsStrictKey() throws {
        let nonStrict = ToolDefinition(
            name: "get_weather",
            description: "Get the weather",
            parametersSchema: .object(properties: ["city": .string()], required: ["city"])
        )
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [nonStrict])
        let data = try JSONEncoder().encode(request)
        let tools = try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["tools"]
            as? [[String: Any]]
        let function = tools?[0]["function"] as? [String: Any]
        #expect(function?["strict"] == nil)
    }
}

struct OpenAIChatRequestSurfaceTests {
    @Test
    func firstPartyCustomToolEncodes() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            options: OpenAIChatRequestOptions(customTools: [
                OpenAIChatCustomToolDefinition(
                    name: "grammar_query",
                    description: "Run a grammar-constrained query",
                    format: .grammar(definition: "start: WORD", syntax: .lark)
                )
            ])
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "custom")
        let custom = try #require(tools[0]["custom"] as? [String: Any])
        #expect(custom["name"] as? String == "grammar_query")
        let format = try #require(custom["format"] as? [String: Any])
        #expect(format["type"] as? String == "grammar")
    }

    @Test
    func customToolChoiceAndParallelToolCallsEncode() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            options: OpenAIChatRequestOptions(
                toolChoice: .custom(name: "grammar_query"),
                parallelToolCalls: false,
                customTools: [OpenAIChatCustomToolDefinition(name: "grammar_query")]
            )
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let toolChoice = try #require(json["tool_choice"] as? [String: Any])
        #expect(toolChoice["type"] as? String == "custom")
        let custom = try #require(toolChoice["custom"] as? [String: Any])
        #expect(custom["name"] as? String == "grammar_query")
        #expect(json["parallel_tool_calls"] as? Bool == false)
    }

    @Test
    func allowedToolsEncodesForFirstParty() throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            parametersSchema: .object(properties: ["city": .string()], required: ["city"])
        )
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [tool],
            options: OpenAIChatRequestOptions(
                toolChoice: .allowedTools(tools: [.function(name: "get_weather")])
            )
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let toolChoice = try #require(json["tool_choice"] as? [String: Any])
        #expect(toolChoice["type"] as? String == "allowed_tools")
        let allowedTools = try #require(toolChoice["allowed_tools"] as? [String: Any])
        #expect(allowedTools["mode"] as? String == "auto")
        let toolsJSON = try #require(allowedTools["tools"] as? [[String: Any]])
        #expect(toolsJSON.count == 1)
        #expect(toolsJSON[0]["type"] as? String == "function")
        let function = try #require(toolsJSON[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_weather")
    }

    @Test
    func allowedToolsRequiredModeEncodes() throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            parametersSchema: .object(properties: ["city": .string()], required: ["city"])
        )
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [tool],
            options: OpenAIChatRequestOptions(
                toolChoice: .allowedTools(mode: .required, tools: [.function(name: "get_weather")])
            )
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowedTools = try #require(
            (json["tool_choice"] as? [String: Any])?["allowed_tools"] as? [String: Any]
        )
        #expect(allowedTools["mode"] as? String == "required")
    }

    @Test
    func compatibleProfileRejectsCustomTools() throws {
        let client = OpenAIClient.proxy(baseURL: OpenAIClient.groqBaseURL)
        #expect(throws: AgentError.self) {
            _ = try client.buildRequest(
                messages: [.user("Hi")],
                tools: [],
                options: OpenAIChatRequestOptions(
                    customTools: [OpenAIChatCustomToolDefinition(name: "grammar_query")]
                )
            )
        }
    }

    @Test
    func firstPartyProfileUsesCapabilityTokenFieldOnCustomBaseURL() throws {
        let client = try OpenAIClient(
            apiKey: "k",
            model: "gpt-5.4",
            baseURL: #require(URL(string: "https://gateway.example.com/v1")),
            profile: .firstParty
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["max_completion_tokens"] as? Int == 16384)
        #expect(json["max_tokens"] == nil)
    }
}

struct OpenAIChatCustomToolStreamingTests {
    private let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")

    @Test
    func customToolCallStreamingDelta_emitsCustomKind() throws {
        let chunk = Data(#"""
        {
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_custom1",
                        "type": "custom",
                        "custom": {"name": "grammar_query", "input": "SELECT *"}
                    }]
                },
                "finish_reason": null
            }]
        }
        """#.utf8)
        let parsed = try client.parseStreamingChunk(chunk)
        let deltas = try client.extractDeltas(from: parsed)

        let startIndex = deltas.firstIndex {
            if case .toolCallStart = $0 { true } else { false }
        }
        let start = try #require(startIndex.map { deltas[$0] })
        guard case let .toolCallStart(index, id, name, kind) = start else {
            Issue.record("expected toolCallStart"); return
        }
        #expect(index == 0)
        #expect(id == "call_custom1")
        #expect(name == "grammar_query")
        #expect(kind == .custom)

        let delta = deltas.first {
            if case .toolCallDelta = $0 { true } else { false }
        }
        guard case let .toolCallDelta(_, arguments) = try #require(delta) else {
            Issue.record("expected toolCallDelta"); return
        }
        #expect(arguments == "SELECT *")
    }

    @Test
    func unknownStreamingToolCallType_throwsFeatureUnsupported() throws {
        let chunk = Data(#"""
        {
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_mcp1",
                        "type": "mcp"
                    }]
                },
                "finish_reason": null
            }]
        }
        """#.utf8)
        let parsed = try client.parseStreamingChunk(chunk)
        #expect(throws: AgentError.self) {
            _ = try client.extractDeltas(from: parsed)
        }
    }
}
