@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesEdgeCaseTests {
    @Test
    func emptyToolsArrayOmitsToolsField() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL, store: false
        )
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["tools"] == nil)
    }

    @Test
    func strictToolDefinitionEncodesStrictTrueInRequest() async throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            parametersSchema: .object(properties: ["city": .string()], required: ["city"]),
            strict: true
        )
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL, store: false
        )
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [tool])
        let json = try encodeRequest(request)

        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        #expect(tools[0]["name"] as? String == "get_weather")
        #expect(tools[0]["strict"] as? Bool == true)
    }

    @Test
    func strictToolDefinitionEncodesStrictFalseInRequest() async throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            parametersSchema: .object(properties: ["city": .string()], required: ["city"]),
            strict: false
        )
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL, store: false
        )
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [tool])
        let json = try encodeRequest(request)

        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["strict"] as? Bool == false)
    }

    @Test
    func nilStrictToolDefinitionOmitsStrictInRequest() async throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            parametersSchema: .object(properties: ["city": .string()], required: ["city"])
        )
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL, store: false
        )
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [tool])
        let json = try encodeRequest(request)

        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["strict"] == nil)
    }

    @Test
    func emptyOutputArrayParsesToEmptyMessage() async throws {
        let json = """
        {
            "id": "resp_empty",
            "status": "completed",
            "output": [],
            "usage": {"input_tokens": 10, "output_tokens": 0}
        }
        """
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let response = try await client.decodeResponse(Data(json.utf8))
        let msg = await client.parseResponse(response)

        #expect(msg.content == "")
        #expect(msg.toolCalls.isEmpty)
        #expect(msg.tokenUsage?.input == 10)
        #expect(msg.tokenUsage?.output == 0)
    }

    @Test
    func usageWithoutReasoningTokensDefaultsToZero() async throws {
        let json = """
        {
            "id": "resp_no_reasoning",
            "status": "completed",
            "output": [{"type": "message", "content": [{"type": "output_text", "text": "Hi"}]}],
            "usage": {"input_tokens": 50, "output_tokens": 20, "output_tokens_details": {}}
        }
        """
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let response = try await client.decodeResponse(Data(json.utf8))
        let msg = await client.parseResponse(response)

        #expect(msg.tokenUsage == TokenUsage(input: 50, output: 20, reasoning: 0))
    }

    @Test
    func multimodalWithImagePartEncodesInputImage() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let messages: [ChatMessage] = [
            .userMultimodal([.text("Look at this"), .imageURL("https://example.com/img.png")])
        ]

        let request = try await client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)
        let input = try #require(json["input"] as? [[String: Any]])
        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == "Look at this")
        #expect(content[1]["type"] as? String == "input_image")
        #expect(content[1]["image_url"] as? String == "https://example.com/img.png")
    }

    @Test
    func multimodalWithOnlyTextPartsSucceeds() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key", model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let messages: [ChatMessage] = [
            .userMultimodal([.text("Part one"), .text("Part two")])
        ]

        let request = try await client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)
        let input = json["input"] as? [[String: Any]]
        #expect(input?[0]["content"] as? String == "Part one\nPart two")
    }
}
