@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesURLRequestTests {
    @Test(arguments: Endpoint.allCases, [false, true])
    func cacheIdentifiersReachURLRequest(endpoint: Endpoint, stream: Bool) async throws {
        let client = endpoint.makeClient()
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: [], stream: stream,
            extraFields: [
                "prompt_cache_key": .string("shared-prefix-v1"),
                "safety_identifier": .string("user-digest-123"),
                "user": .string("legacy-user")
            ]
        )
        let urlRequest = try await client.buildURLRequest(request)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(urlRequest.httpBody))

        #expect(urlRequest.url?.absoluteString == endpoint.url)
        #expect(body["prompt_cache_key"] == .string("shared-prefix-v1"))
        #expect(body["safety_identifier"] == .string("user-digest-123"))
        #expect(body["user"] == .string("legacy-user"))
        #expect(body["stream"] == (stream ? .bool(true) : nil))
    }

    @Test(arguments: Endpoint.allCases, ["model", "input", "tools", "stream", "previous_response_id", "unknown"])
    func reservedAndUnknownExtraFieldsFailURLRequestEncoding(endpoint: Endpoint, key: String) async throws {
        let client = endpoint.makeClient()
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: [], stream: true,
            extraFields: [key: .string("override")]
        )
        do {
            _ = try await client.buildURLRequest(request)
            Issue.record("Expected invalid extra field to fail request encoding")
        } catch let AgentError.llmError(.encodingFailed(description)) {
            #expect(description.contains(key))
        }
    }

    @Test(arguments: [false, true])
    func nestedSchemaBodyHasDeterministicObjectOrder(stream: Bool) async throws {
        let client = ResponsesAPIClient(model: "test", baseURL: ResponsesAPIClient.openAIBaseURL, store: false)
        let tool = ToolDefinition(
            name: "inspect", description: "Inspect", parametersSchema: HTTPJSONTestParameters.jsonSchema
        )
        let request = try await client.buildRequest(messages: [.user("z"), .user("a")], tools: [tool], stream: stream)
        let urlRequest = try await client.buildURLRequest(request)
        let streamJSON = stream ? #","stream":true"# : ""
        let expected = #"{"include":["reasoning.encrypted_content"],"input":[{"content":"z","role":"user","#
            + #""type":"message"},{"content":"a","role":"user","type":"message"}],"model":"test","store":false"#
            + streamJSON
            + #","tools":[{"description":"Inspect","name":"inspect","parameters":"#
            + HTTPJSONTestParameters.schemaJSON + #","type":"function"}]}"#

        #expect(urlRequest.httpBody == Data(expected.utf8))
    }

    @Test
    func buildURLRequestSetsCorrectProperties() async throws {
        let client = ResponsesAPIClient(
            apiKey: "sk-test-123",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
    }

    @Test
    func buildURLRequestAppliesAdditionalHeaders() async throws {
        let client = ResponsesAPIClient(
            apiKey: "sk-test-123",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            additionalHeaders: { ["X-Custom-Header": "custom-value"] }
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "X-Custom-Header") == "custom-value")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
    }

    @Test
    func additionalAuthorizationHeaderOverridesApiKeyCaseInsensitively() async throws {
        let client = ResponsesAPIClient(
            apiKey: "sk-test-123",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            additionalHeaders: { ["authorization": "Bearer override"] }
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer override")
    }

    @Test
    func buildURLRequestWithoutApiKeyOmitsAuth() async throws {
        let client = ResponsesAPIClient(
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func customResponsesPath() async throws {
        let client = try ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: #require(URL(string: "https://custom.api.com/v2")),
            responsesPath: "custom/responses"
        )
        let request = try await client.buildRequest(
            messages: [.user("Hello")], tools: []
        )
        let urlRequest = try await client.buildURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://custom.api.com/v2/custom/responses")
    }

    enum Endpoint: CaseIterable {
        case openAI, openRouter

        var url: String {
            switch self {
            case .openAI: "https://api.openai.com/v1/responses"
            case .openRouter: "https://openrouter.ai/api/v1/responses"
            }
        }

        func makeClient() -> ResponsesAPIClient {
            switch self {
            case .openAI:
                ResponsesAPIClient(
                    apiKey: "test-key", model: "gpt-4.1", baseURL: ResponsesAPIClient.openAIBaseURL
                )
            case .openRouter:
                ResponsesAPIClient.openRouter(apiKey: "test-key", model: "gpt-4.1")
            }
        }
    }
}
