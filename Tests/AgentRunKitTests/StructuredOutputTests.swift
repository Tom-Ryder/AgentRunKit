import Foundation
import Testing

@testable import AgentRunKit

struct TestStructuredOutput: Codable, SchemaProviding, Equatable {
    let name: String
    let count: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "name": .string(),
                "count": .integer()
            ],
            required: ["name", "count"]
        )
    }
}

struct GenericWrapper<T>: SchemaProviding {
    static var jsonSchema: JSONSchema { .string() }
}

@Suite
struct ResponseFormatTests {
    @Test
    func encodesCorrectly() throws {
        let format = ResponseFormat.jsonSchema(TestStructuredOutput.self)
        let encoder = JSONEncoder()
        let data = try encoder.encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["type"] as? String == "json_schema")

        let jsonSchema = json?["json_schema"] as? [String: Any]
        #expect(jsonSchema?["name"] as? String == "TestStructuredOutput")
        #expect(jsonSchema?["strict"] as? Bool == true)

        let schema = jsonSchema?["schema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object")
        #expect(schema?["additionalProperties"] as? Bool == false)

        let properties = schema?["properties"] as? [String: Any]
        #expect(properties?["name"] != nil)
        #expect(properties?["count"] != nil)
    }

    @Test
    func sanitizesGenericTypeNames() throws {
        let format = ResponseFormat.jsonSchema(GenericWrapper<String>.self)
        let encoder = JSONEncoder()
        let data = try encoder.encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let jsonSchema = json?["json_schema"] as? [String: Any]
        let name = jsonSchema?["name"] as? String
        #expect(name == "GenericWrapper_String_")
        #expect(name?.contains("<") == false)
        #expect(name?.contains(">") == false)
    }
}

@Suite
struct ChatCompletionRequestResponseFormatTests {
    @Test
    func requestWithResponseFormatEncodesCorrectly() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Extract data")]
        let format = ResponseFormat.jsonSchema(TestStructuredOutput.self)
        let request = client.buildRequest(
            messages: messages,
            tools: [],
            responseFormat: format
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let responseFormat = json?["response_format"] as? [String: Any]
        #expect(responseFormat?["type"] as? String == "json_schema")

        let jsonSchema = responseFormat?["json_schema"] as? [String: Any]
        #expect(jsonSchema?["name"] as? String == "TestStructuredOutput")
        #expect(jsonSchema?["strict"] as? Bool == true)
    }

    @Test
    func requestWithoutResponseFormatOmitsField() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "test/model",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(messages: messages, tools: [])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["response_format"] == nil)
    }
}

actor StructuredOutputMockLLMClient: LLMClient {
    private let jsonContent: String

    init(jsonContent: String) {
        self.jsonContent = jsonContent
    }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?
    ) async throws -> AssistantMessage {
        AssistantMessage(content: jsonContent)
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite
struct ChatStructuredOutputTests {
    @Test
    func sendDecodesValidJSON() async throws {
        let client = StructuredOutputMockLLMClient(jsonContent: "{\"name\":\"test\",\"count\":42}")
        let chat = Chat<EmptyContext>(client: client)

        let result = try await chat.send("Extract", returning: TestStructuredOutput.self)

        #expect(result.name == "test")
        #expect(result.count == 42)
    }

    @Test
    func sendThrowsOnMalformedJSON() async throws {
        let client = StructuredOutputMockLLMClient(jsonContent: "not valid json")
        let chat = Chat<EmptyContext>(client: client)

        do {
            _ = try await chat.send("Extract", returning: TestStructuredOutput.self)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case .structuredOutputDecodingFailed = error else {
                Issue.record("Expected structuredOutputDecodingFailed, got \(error)")
                return
            }
        }
    }

    @Test
    func sendThrowsOnMissingFields() async throws {
        let client = StructuredOutputMockLLMClient(jsonContent: "{\"name\":\"test\"}")
        let chat = Chat<EmptyContext>(client: client)

        do {
            _ = try await chat.send("Extract", returning: TestStructuredOutput.self)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case .structuredOutputDecodingFailed = error else {
                Issue.record("Expected structuredOutputDecodingFailed, got \(error)")
                return
            }
        }
    }
}

@Suite
struct JSONSchemaAdditionalPropertiesTests {
    @Test
    func objectSchemaIncludesAdditionalPropertiesFalse() throws {
        let schema = JSONSchema.object(
            properties: ["field": .string()],
            required: ["field"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(schema)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["additionalProperties"] as? Bool == false)
    }

    @Test
    func nestedObjectSchemaIncludesAdditionalPropertiesFalse() throws {
        let schema = JSONSchema.object(
            properties: [
                "nested": .object(
                    properties: ["inner": .string()],
                    required: ["inner"]
                )
            ],
            required: ["nested"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(schema)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["additionalProperties"] as? Bool == false)

        let properties = json?["properties"] as? [String: Any]
        let nested = properties?["nested"] as? [String: Any]
        #expect(nested?["additionalProperties"] as? Bool == false)
    }
}
