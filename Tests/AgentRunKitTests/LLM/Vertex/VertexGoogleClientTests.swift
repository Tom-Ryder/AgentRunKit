@testable import AgentRunKit
import Foundation
import Testing

struct VertexGoogleURLTests {
    private func makeClient(
        projectID: String = "test-project",
        location: String = "us-central1",
        model: String = "gemini-2.5-pro",
        apiVersion: String = "v1beta1",
        reasoningConfig: ReasoningConfig? = nil
    ) -> VertexGoogleClient {
        VertexGoogleClient(
            projectID: projectID,
            location: location,
            model: model,
            tokenProvider: { "test-token-123" },
            apiVersion: apiVersion,
            reasoningConfig: reasoningConfig
        )
    }

    @Test
    func vertexURLHasCorrectPath() throws {
        let client = makeClient()
        let request = try client.gemini.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: false, token: "tok")

        let url = try #require(urlRequest.url)
        #expect(url.absoluteString.contains("/projects/test-project/"))
        #expect(url.absoluteString.contains("/locations/us-central1/"))
        #expect(url.absoluteString.contains("/publishers/google/models/gemini-2.5-pro:generateContent"))
        #expect(url.host == "us-central1-aiplatform.googleapis.com")
    }

    @Test
    func vertexStreamURLHasStreamAction() throws {
        let client = makeClient()
        let request = try client.gemini.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: true, token: "tok")

        let url = try #require(urlRequest.url)
        #expect(url.absoluteString.contains(":streamGenerateContent"))
        #expect(url.query?.contains("alt=sse") == true)
    }

    @Test
    func vertexURLUsesCorrectApiVersion() throws {
        let client = makeClient(apiVersion: "v1")
        let request = try client.gemini.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: false, token: "tok")

        #expect(urlRequest.url?.absoluteString.contains("/v1/projects/") == true)
    }

    @Test
    func noApiKeyInQueryParams() throws {
        let client = makeClient()
        let request = try client.gemini.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: false, token: "tok")

        #expect(urlRequest.url?.query?.contains("key=") != true)
    }

    @Test
    func bearerTokenInAuthHeader() throws {
        let client = makeClient()
        let request = try client.gemini.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: false, token: "my-oauth-token")

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer my-oauth-token")
    }

    @Test
    func requestBodyHasContents() throws {
        let client = makeClient()
        let request = try client.gemini.buildRequest(messages: [.user("Hello")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: false, token: "tok")

        let body = try #require(urlRequest.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        let contents = json["contents"] as? [[String: Any]]
        #expect(contents?.count == 1)
        let parts = contents?[0]["parts"] as? [[String: Any]]
        #expect(parts?[0]["text"] as? String == "Hello")
    }

    @Test
    func differentLocationsChangeHost() throws {
        let client = makeClient(location: "europe-west1")
        let request = try client.gemini.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: false, token: "tok")

        #expect(urlRequest.url?.host == "europe-west1-aiplatform.googleapis.com")
        #expect(urlRequest.url?.absoluteString.contains("/locations/europe-west1/") == true)
    }

    @Test
    func httpMethodIsPost() throws {
        let client = makeClient()
        let request = try client.gemini.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: false, token: "tok")

        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
}

struct VertexGoogleStreamingCompletionTests {
    @Test
    func publicStreamEndingBeforeFinishReasonThrowsStreamStalled() async throws {
        let session = URLSession(configuration: StreamingTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client = VertexGoogleClient(
            projectID: "test-project",
            location: "us-central1",
            model: "gemini-2.5-pro",
            tokenProvider: { "test-token-123" },
            session: session
        )
        let request = try client.gemini.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: true, token: "test-token-123")
        let requestURL = try #require(urlRequest.url)
        let body = "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"partial\"}]}}]}\n\n"
        StreamingTestURLProtocol.register(url: requestURL, body: Data(body.utf8))
        defer { StreamingTestURLProtocol.unregister(url: requestURL) }

        let result = await collectStreamResult(client.stream(messages: [.user("Hi")], tools: [], requestContext: nil))

        #expect(result.deltas == [.content("partial")])
        assertStreamStalled(result.error)
    }
}

struct VertexGoogleResponseTests {
    @Test
    func responseParsingDelegatedToGemini() throws {
        let client = VertexGoogleClient(
            projectID: "p", location: "l", model: "m",
            tokenProvider: { "tok" }
        )
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [{"text": "Hello from Vertex!"}]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 10,
                "candidatesTokenCount": 5
            }
        }
        """
        let msg = try client.gemini.parseResponse(Data(json.utf8))
        #expect(msg.content == "Hello from Vertex!")
        #expect(msg.tokenUsage?.input == 10)
        #expect(msg.tokenUsage?.output == 5)
    }

    @Test
    func thinkingConfigPassedThrough_onGemini3() throws {
        let client = VertexGoogleClient(
            projectID: "p", location: "l", model: "gemini-3-flash-preview",
            tokenProvider: { "tok" },
            reasoningConfig: .high
        )
        let config = try client.gemini.buildThinkingConfig()
        #expect(config?.thinkingLevel == "HIGH")
        #expect(config?.thinkingBudget == nil)
        #expect(config?.includeThoughts == true)
    }

    @Test
    func thinkingConfigPassedThrough_onGemini25() throws {
        let client = VertexGoogleClient(
            projectID: "p", location: "l", model: "gemini-2.5-pro",
            tokenProvider: { "tok" },
            reasoningConfig: .high
        )
        let config = try client.gemini.buildThinkingConfig()
        #expect(config?.thinkingBudget == 16384)
        #expect(config?.thinkingLevel == nil)
        #expect(config?.includeThoughts == true)
    }
}

struct VertexGoogleHistoryValidationTests {
    private let malformedHistory: [ChatMessage] = [
        .user("Hi"),
        .assistant(AssistantMessage(
            content: "",
            toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
        )),
    ]

    @Test
    func generateRejectsMalformedHistory() async {
        let client = VertexGoogleClient(
            projectID: "p",
            location: "l",
            model: "m",
            tokenProvider: { "tok" }
        )

        await #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
            _ = try await client.generate(
                messages: malformedHistory,
                tools: [],
                responseFormat: nil,
                requestContext: nil
            )
        }
    }

    @Test
    func streamRejectsMalformedHistory() async {
        let client = VertexGoogleClient(
            projectID: "p",
            location: "l",
            model: "m",
            tokenProvider: { "tok" }
        )

        await #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
            for try await _ in client.stream(messages: malformedHistory, tools: [], requestContext: nil) {}
        }
    }
}
