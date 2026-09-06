@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesURLRequestTests {
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
}
