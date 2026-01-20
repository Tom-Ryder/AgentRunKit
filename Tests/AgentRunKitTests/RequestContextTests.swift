import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct JSONValueEncodingTests {
    @Test
    func encodesString() throws {
        let value = JSONValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "\"hello\"")
    }

    @Test
    func encodesInt() throws {
        let value = JSONValue.int(42)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "42")
    }

    @Test
    func encodesDouble() throws {
        let value = JSONValue.double(3.14)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "3.14")
    }

    @Test
    func encodesBool() throws {
        let trueValue = JSONValue.bool(true)
        let falseValue = JSONValue.bool(false)
        #expect(try String(data: JSONEncoder().encode(trueValue), encoding: .utf8) == "true")
        #expect(try String(data: JSONEncoder().encode(falseValue), encoding: .utf8) == "false")
    }

    @Test
    func encodesNull() throws {
        let value = JSONValue.null
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "null")
    }

    @Test
    func encodesArray() throws {
        let value = JSONValue.array([.int(1), .string("two"), .bool(true)])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "[1,\"two\",true]")
    }

    @Test
    func encodesObject() throws {
        let value = JSONValue.object(["key": .string("value")])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "{\"key\":\"value\"}")
    }

    @Test
    func encodesNestedStructures() throws {
        let value = JSONValue.object([
            "nested": .object(["inner": .array([.int(1), .int(2)])])
        ])
        let data = try JSONEncoder().encode(value)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Failed to parse JSON")
            return
        }
        let nested = parsed["nested"] as? [String: Any]
        let inner = nested?["inner"] as? [Int]
        #expect(inner == [1, 2])
    }
}

@Suite
struct JSONValueEquatableTests {
    @Test
    func stringEquality() {
        #expect(JSONValue.string("a") == JSONValue.string("a"))
        #expect(JSONValue.string("a") != JSONValue.string("b"))
    }

    @Test
    func intEquality() {
        #expect(JSONValue.int(1) == JSONValue.int(1))
        #expect(JSONValue.int(1) != JSONValue.int(2))
    }

    @Test
    func doubleEquality() {
        #expect(JSONValue.double(1.5) == JSONValue.double(1.5))
        #expect(JSONValue.double(1.5) != JSONValue.double(2.5))
    }

    @Test
    func boolEquality() {
        #expect(JSONValue.bool(true) == JSONValue.bool(true))
        #expect(JSONValue.bool(true) != JSONValue.bool(false))
    }

    @Test
    func nullEquality() {
        #expect(JSONValue.null == JSONValue.null)
    }

    @Test
    func arrayEquality() {
        #expect(JSONValue.array([.int(1)]) == JSONValue.array([.int(1)]))
        #expect(JSONValue.array([.int(1)]) != JSONValue.array([.int(2)]))
    }

    @Test
    func objectEquality() {
        #expect(JSONValue.object(["a": .int(1)]) == JSONValue.object(["a": .int(1)]))
        #expect(JSONValue.object(["a": .int(1)]) != JSONValue.object(["a": .int(2)]))
    }

    @Test
    func differentTypesNotEqual() {
        #expect(JSONValue.int(1) != JSONValue.double(1.0))
        #expect(JSONValue.string("1") != JSONValue.int(1))
    }
}

@Suite
struct RequestContextTests {
    @Test
    func initializesWithDefaults() {
        let context = RequestContext()
        #expect(context.extraFields.isEmpty)
        #expect(context.onResponse == nil)
    }

    @Test
    func initializesWithExtraFields() {
        let context = RequestContext(extraFields: ["temperature": .double(0.7)])
        #expect(context.extraFields["temperature"] == .double(0.7))
    }

    @Test
    func initializesWithOnResponse() {
        let context = RequestContext(onResponse: { _ in })
        #expect(context.onResponse != nil)
    }
}

@Suite
struct ChatCompletionRequestExtraFieldsTests {
    @Test
    func requestWithExtraFieldsIncludesThem() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "openai/gpt-oss-120b",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(
            messages: messages,
            tools: [],
            extraFields: ["temperature": .double(0.7), "top_p": .double(0.9)]
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["model"] as? String == "openai/gpt-oss-120b")
        #expect(json?["temperature"] as? Double == 0.7)
        #expect(json?["top_p"] as? Double == 0.9)
    }

    @Test
    func requestWithEmptyExtraFieldsProducesNormalJSON() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "openai/gpt-oss-120b",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(messages: messages, tools: [], extraFields: [:])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["model"] as? String == "openai/gpt-oss-120b")
        #expect(json?["temperature"] == nil)
    }

    @Test
    func extraFieldsWithNestedStructures() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "openai/gpt-oss-120b",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(
            messages: messages,
            tools: [],
            extraFields: [
                "metadata": .object(["user_id": .string("123")]),
                "stop": .array([.string("END"), .string("STOP")])
            ]
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metadata = json?["metadata"] as? [String: Any]
        #expect(metadata?["user_id"] as? String == "123")

        let stop = json?["stop"] as? [String]
        #expect(stop == ["END", "STOP"])
    }

    @Test
    func extraFieldsWithAllValueTypes() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "openai/gpt-oss-120b",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(
            messages: messages,
            tools: [],
            extraFields: [
                "string_field": .string("text"),
                "int_field": .int(42),
                "double_field": .double(3.14),
                "bool_field": .bool(true),
                "null_field": .null
            ]
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["string_field"] as? String == "text")
        #expect(json?["int_field"] as? Int == 42)
        #expect(json?["double_field"] as? Double == 3.14)
        #expect(json?["bool_field"] as? Bool == true)
        #expect(json?["null_field"] is NSNull)
    }
}

@Suite
struct ReasoningConfigEncodingTests {
    @Test
    func reasoningEffortEncodesAsNestedObject() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "openai/gpt-oss-120b",
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: .high
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let reasoning = json?["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "high")
        #expect(reasoning?["max_tokens"] == nil)
        #expect(reasoning?["exclude"] == nil)

        #expect(json?["reasoning_effort"] == nil)
    }

    @Test
    func withoutReasoningConfigOmitsReasoningField() throws {
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "openai/gpt-oss-120b",
            baseURL: OpenAIClient.openRouterBaseURL
        )
        let messages: [ChatMessage] = [.user("Hello")]
        let request = client.buildRequest(messages: messages, tools: [])

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["reasoning_effort"] == nil)
        #expect(json?["reasoning"] == nil)
    }

    @Test
    func allEffortLevelsEncodeCorrectRawValue() throws {
        let efforts: [(ReasoningConfig, String)] = [
            (.xhigh, "xhigh"),
            (.high, "high"),
            (.medium, "medium"),
            (.low, "low"),
            (.minimal, "minimal")
        ]

        for (config, expected) in efforts {
            let client = OpenAIClient(
                apiKey: "test-key",
                model: "openai/gpt-oss-120b",
                baseURL: OpenAIClient.openRouterBaseURL,
                reasoningConfig: config
            )
            let request = client.buildRequest(messages: [.user("Hi")], tools: [])
            let data = try JSONEncoder().encode(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            let reasoning = json?["reasoning"] as? [String: Any]
            #expect(reasoning?["effort"] as? String == expected)
        }
    }

    @Test
    func reasoningWithMaxTokensEncodesNestedMaxTokens() throws {
        let config = ReasoningConfig(effort: .high, maxTokens: 8192)
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "openai/gpt-oss-120b",
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: config
        )
        let request = client.buildRequest(messages: [.user("Hi")], tools: [])
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let reasoning = json?["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "high")
        #expect(reasoning?["max_tokens"] as? Int == 8192)
        #expect(reasoning?["exclude"] == nil)
    }

    @Test
    func reasoningWithExcludeEncodesNestedExclude() throws {
        let config = ReasoningConfig(effort: .medium, exclude: true)
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "openai/gpt-oss-120b",
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: config
        )
        let request = client.buildRequest(messages: [.user("Hi")], tools: [])
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let reasoning = json?["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "medium")
        #expect(reasoning?["max_tokens"] == nil)
        #expect(reasoning?["exclude"] as? Bool == true)
    }

    @Test
    func reasoningWithAllFieldsEncodesCompletely() throws {
        let config = ReasoningConfig(effort: .low, maxTokens: 4096, exclude: false)
        let client = OpenAIClient(
            apiKey: "test-key",
            model: "openai/gpt-oss-120b",
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: config
        )
        let request = client.buildRequest(messages: [.user("Hi")], tools: [])
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let reasoning = json?["reasoning"] as? [String: Any]
        #expect(reasoning?["effort"] as? String == "low")
        #expect(reasoning?["max_tokens"] as? Int == 4096)
        #expect(reasoning?["exclude"] as? Bool == false)
    }
}
