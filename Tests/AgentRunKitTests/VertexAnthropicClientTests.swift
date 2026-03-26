@testable import AgentRunKit
import Foundation
import Testing

struct VertexAnthropicURLTests {
    private func makeClient(
        projectID: String = "test-project",
        location: String = "us-east5",
        model: String = "claude-sonnet-4-6"
    ) -> VertexAnthropicClient {
        VertexAnthropicClient(
            projectID: projectID,
            location: location,
            model: model,
            tokenProvider: { "test-token-123" }
        )
    }

    @Test
    func vertexURLHasCorrectPath() throws {
        let client = makeClient()
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "tok")

        let url = try #require(urlRequest.url)
        #expect(url.absoluteString.contains("/projects/test-project/"))
        #expect(url.absoluteString.contains("/locations/us-east5/"))
        #expect(url.absoluteString.contains("/publishers/anthropic/models/claude-sonnet-4-6:rawPredict"))
        #expect(url.host == "us-east5-aiplatform.googleapis.com")
    }

    @Test
    func vertexStreamURLUsesStreamRawPredict() throws {
        let client = makeClient()
        let request = try client.anthropic.buildRequest(
            messages: [.user("Hi")], tools: [], stream: true
        )
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: true, token: "tok")

        #expect(urlRequest.url?.absoluteString.contains(":streamRawPredict") == true)
    }

    @Test
    func bearerTokenInAuthHeader() throws {
        let client = makeClient()
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "my-oauth-token")

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer my-oauth-token")
    }

    @Test
    func noApiKeyHeader() throws {
        let client = makeClient()
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "tok")

        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == nil)
    }

    @Test
    func httpMethodIsPost() throws {
        let client = makeClient()
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "tok")

        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func differentLocationsChangeHost() throws {
        let client = makeClient(location: "europe-west4")
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "tok")

        #expect(urlRequest.url?.host == "europe-west4-aiplatform.googleapis.com")
        #expect(urlRequest.url?.absoluteString.contains("/locations/europe-west4/") == true)
    }
}

struct VertexAnthropicRequestTests {
    @Test
    func requestBodyContainsAnthropicVersion() throws {
        let client = VertexAnthropicClient(
            projectID: "p", location: "l", model: "m",
            tokenProvider: { "tok" }
        )
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let data = try JSONEncoder().encode(wrapped)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["anthropic_version"] as? String == "vertex-2023-10-16")
    }

    @Test
    func requestBodyPreservesAnthropicFields() throws {
        let client = VertexAnthropicClient(
            projectID: "p", location: "l", model: "claude-sonnet-4-6",
            tokenProvider: { "tok" },
            maxTokens: 4096
        )
        let tools = [
            ToolDefinition(
                name: "search", description: "Search",
                parametersSchema: .object(properties: ["q": .string()], required: ["q"])
            )
        ]
        let request = try client.anthropic.buildRequest(
            messages: [.system("Be helpful"), .user("Hello")], tools: tools
        )
        let wrapped = VertexAnthropicRequest(inner: request)
        let data = try JSONEncoder().encode(wrapped)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["max_tokens"] as? Int == 4096)
        #expect(json["model"] == nil, "model must not appear in Vertex request body")

        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?[0]["role"] as? String == "user")

        let system = json["system"] as? [[String: Any]]
        #expect(system?.count == 1)
        #expect(system?[0]["text"] as? String == "Be helpful")

        let jsonTools = json["tools"] as? [[String: Any]]
        #expect(jsonTools?.count == 1)
        #expect(jsonTools?[0]["name"] as? String == "search")

        #expect(json["anthropic_version"] as? String == "vertex-2023-10-16")
    }

    @Test
    func streamFieldEncodesInBody() throws {
        let client = VertexAnthropicClient(
            projectID: "p", location: "l", model: "m",
            tokenProvider: { "tok" }
        )
        let request = try client.anthropic.buildRequest(
            messages: [.user("Hi")], tools: [], stream: true
        )
        let wrapped = VertexAnthropicRequest(inner: request)
        let data = try JSONEncoder().encode(wrapped)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["stream"] as? Bool == true)
        #expect(json["anthropic_version"] as? String == "vertex-2023-10-16")
    }
}

struct VertexAnthropicResponseTests {
    @Test
    func responseParsingDelegatedToAnthropic() throws {
        let client = VertexAnthropicClient(
            projectID: "p", location: "l", model: "m",
            tokenProvider: { "tok" }
        )
        let json = """
        {
            "id": "msg_001",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Hello from Vertex!"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 100, "output_tokens": 50}
        }
        """
        let msg = try client.anthropic.parseResponse(Data(json.utf8))
        #expect(msg.content == "Hello from Vertex!")
        #expect(msg.tokenUsage?.input == 100)
        #expect(msg.tokenUsage?.output == 50)
    }

    @Test
    func responseFormatThrows() async {
        let client = VertexAnthropicClient(
            projectID: "p", location: "l", model: "m",
            tokenProvider: { "tok" }
        )
        let format = ResponseFormat.jsonSchema(TestVertexAnthropicOutput.self)
        await #expect(throws: AgentError.self) {
            _ = try await client.generate(
                messages: [.user("Hi")],
                tools: [],
                responseFormat: format
            )
        }
    }
}

private enum TestVertexAnthropicOutput: SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: ["value": .string()], required: ["value"])
    }
}
