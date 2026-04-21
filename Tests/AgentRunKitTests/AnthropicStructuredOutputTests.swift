@testable import AgentRunKit
import Foundation
import Testing

private struct AnthropicWeatherResult: Codable, SchemaProviding, Equatable {
    let city: String
    let tempC: Int
}

struct AnthropicStructuredOutputTests {
    private func encodeRequest(_ request: AnthropicRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func responseFormat_emitsOutputConfigFormat_independentOfThinking() throws {
        let client = try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            responseFormat: .jsonSchema(AnthropicWeatherResult.self)
        )
        let json = try encodeRequest(request)
        let outputConfig = try #require(json["output_config"] as? [String: Any])
        let format = try #require(outputConfig["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(outputConfig["effort"] == nil)
    }

    @Test
    func responseFormat_combinesWithAdaptiveEffort() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            reasoningConfig: .high,
            anthropicReasoning: .adaptive
        )
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            responseFormat: .jsonSchema(AnthropicWeatherResult.self)
        )
        let json = try encodeRequest(request)
        let outputConfig = try #require(json["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "high")
        #expect(outputConfig["format"] != nil)
    }

    @Test
    func noResponseFormat_onManual_omitsOutputConfig() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            reasoningConfig: .high,
            anthropicReasoning: .manual
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)
        #expect(json["output_config"] == nil)
        #expect(json["thinking"] != nil)
    }

    @Test
    func toolChoice_anyWithDisableParallel_encodes() throws {
        let client = try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
        let tools = [ToolDefinition(
            name: "get_weather",
            description: "",
            parametersSchema: .object(properties: ["city": .string()], required: ["city"]),
            strict: true
        )]
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: tools,
            toolChoice: .any(disableParallel: true)
        )
        let json = try encodeRequest(request)

        let choice = try #require(json["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "any")
        #expect(choice["disable_parallel_tool_use"] as? Bool == true)

        let jsonTools = try #require(json["tools"] as? [[String: Any]])
        #expect(jsonTools[0]["strict"] as? Bool == true)
    }

    @Test
    func toolChoice_toolForcesSpecificTool() throws {
        let client = try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
        let tools = [ToolDefinition(
            name: "get_weather",
            description: "",
            parametersSchema: .object(properties: [:], required: [])
        )]
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: tools,
            toolChoice: .tool(name: "get_weather")
        )
        let json = try encodeRequest(request)
        let choice = try #require(json["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "tool")
        #expect(choice["name"] as? String == "get_weather")
    }

    @Test
    func toolChoice_noneEncodes() throws {
        let client = try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            toolChoice: AnthropicToolChoice.none
        )
        let json = try encodeRequest(request)
        let choice = try #require(json["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "none")
    }

    @Test
    func forcedToolChoiceRejectsActiveThinking() throws {
        let client = try AnthropicClient(
            apiKey: "test-key",
            model: "claude-sonnet-4-6",
            reasoningConfig: .high,
            anthropicReasoning: .adaptive
        )
        let tools = [ToolDefinition(
            name: "get_weather",
            description: "",
            parametersSchema: .object(properties: [:], required: [])
        )]
        #expect(throws: AgentError.self) {
            _ = try client.buildRequest(
                messages: [.user("Hi")],
                tools: tools,
                toolChoice: .any()
            )
        }
    }

    @Test
    func haiku45RejectsAdaptiveThinkingAtConstruction() {
        #expect(throws: AgentError.self) {
            _ = try AnthropicClient(
                apiKey: "test-key",
                model: "claude-haiku-4-5",
                reasoningConfig: .high,
                anthropicReasoning: .adaptive
            )
        }
    }

    @Test
    func unknownPreviewRejectsReasoningConfigAtConstruction() {
        #expect(throws: AgentError.self) {
            _ = try AnthropicClient(
                apiKey: "test-key",
                model: "claude-private-preview",
                reasoningConfig: .high,
                anthropicReasoning: .adaptive
            )
        }
    }
}
