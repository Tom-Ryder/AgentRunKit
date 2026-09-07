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

    @Test(arguments: [false, true])
    func nestedSchemaBodyHasDeterministicObjectOrder(stream: Bool) throws {
        let client = makeClient()
        let tool = ToolDefinition(
            name: "inspect", description: "Inspect", parametersSchema: HTTPJSONTestParameters.jsonSchema
        )
        let request = try client.gemini.buildRequest(messages: [.user("z"), .user("a")], tools: [tool])
        let urlRequest = try client.buildVertexURLRequest(request, stream: stream, token: "tok")
        let expected = #"{"contents":[{"parts":[{"text":"z"}],"role":"user"},{"parts":[{"text":"a"}],"role":"user"}],"#
            + #""generationConfig":{"maxOutputTokens":8192},"toolConfig":{"functionCallingConfig":{"mode":"AUTO"}},"#
            + #""tools":[{"functionDeclarations":[{"description":"Inspect","name":"inspect","parameters":"#
            + HTTPJSONTestParameters.geminiSchemaJSON + #"}]}]}"#

        #expect(urlRequest.httpBody == Data(expected.utf8))
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
        let session = URLSession(configuration: HTTPTestURLProtocol.configuration())
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
        HTTPTestURLProtocol.register(url: requestURL, response: HTTPTestResponse(
            body: Data(body.utf8), headers: ["Content-Type": "text/event-stream"]
        ))
        defer { HTTPTestURLProtocol.unregister(url: requestURL) }

        let result = await collectStreamResult(client.stream(messages: [.user("Hi")], tools: [], requestContext: nil))

        #expect(result.deltas == [.content("partial")])
        assertProviderTerminationMissing(result.error)
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
        let msg = try client.gemini.parseResponse(Data(json.utf8), provider: .vertexGoogle)
        #expect(msg.content == "Hello from Vertex!")
        #expect(msg.tokenUsage?.input == 10)
        #expect(msg.tokenUsage?.output == 5)
    }

    @Test
    func errorResponseAttributesVertexProvider() throws {
        let client = VertexGoogleClient(
            projectID: "p", location: "l", model: "m",
            tokenProvider: { "tok" }
        )
        let json = #"{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#

        do {
            _ = try client.gemini.parseResponse(Data(json.utf8), provider: client.providerIdentifier)
            Issue.record("Expected providerError")
        } catch let error as AgentError {
            guard case let .llmError(.providerError(provider, code, message)) = error else {
                Issue.record("Expected providerError, got \(error)")
                return
            }
            #expect(provider == .vertexGoogle)
            #expect(code == "RESOURCE_EXHAUSTED")
            #expect(message == "Quota exceeded")
        }
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

@Suite(.tags(.provider, .wireFormat))
struct VertexGoogleUsageTests {
    enum Execution: CaseIterable {
        case blocking, streaming
    }

    @Test(arguments: GeminiUsageTestFixtures.measurements, Execution.allCases)
    func sharedUsageMappingSurvivesVertexTransport(
        measurement: (metadata: String?, expected: TokenUsage?), execution: Execution
    ) async throws {
        let usage = measurement.metadata.map { #","usageMetadata":\#($0)"# } ?? ""
        let response = #"{"candidates":[{"content":{"parts":[{"text":"Checking"},"#
            + #"{"functionCall":{"id":"call_1","name":"lookup","args":{}}}]},"#
            + #""finishReason":"STOP"}]\#(usage)}"#
        try await withClient(responses: [response], execution: execution) { client in
            switch execution {
            case .blocking:
                let message = try await client.generate(messages: [.user("Work")], tools: [], responseFormat: nil)
                #expect(message.content == "Checking")
                #expect(message.toolCalls == [ToolCall(id: "call_1", name: "lookup", arguments: "{}")])
                #expect(message.tokenUsage == measurement.expected)
            case .streaming:
                var deltas: [StreamDelta] = []
                for try await delta in client.stream(messages: [.user("Work")], tools: []) {
                    deltas.append(delta)
                }
                #expect(deltas == [
                    .content("Checking"), .toolCallStart(index: 0, id: "call_1", name: "lookup", kind: .function),
                    .toolCallDelta(index: 0, arguments: "{}"), .finished(usage: measurement.expected)
                ])
            }
        }
    }

    @Test(arguments: GeminiUsageTestFixtures.malformedScalars, Execution.allCases)
    func malformedToolUseCountFailsVertexTransport(value: String, execution: Execution) async throws {
        let response = #"{"candidates":[{"content":{"parts":[{"text":"Checking"}]},"finishReason":"STOP"}],"#
            + #""usageMetadata":{"toolUsePromptTokenCount":\#(value)}}"#
        try await withClient(responses: [response], execution: execution) { client in
            do {
                switch execution {
                case .blocking:
                    _ = try await client.generate(messages: [.user("Work")], tools: [], responseFormat: nil)
                case .streaming:
                    for try await _ in client.stream(messages: [.user("Work")], tools: []) {}
                }
                Issue.record("Expected malformed tool-use count to fail")
            } catch let AgentError.llmError(.decodingFailed(description)) {
                #expect(description.contains("usageMetadata"))
                #expect(description.contains("toolUsePromptTokenCount"))
            }
        }
    }

    @Test(arguments: Execution.allCases)
    func toolUsePromptCountsCrossTheCumulativeCeiling(execution: Execution) async throws {
        let response = #"{"candidates":[{"content":{"parts":[{"text":"Working"}]},"finishReason":"STOP"}],"#
            + #""usageMetadata":\#(GeminiUsageTestFixtures.toolUseMetadata)}"#
        try await withClient(responses: [response], execution: execution) { client in
            let agent = Agent<EmptyContext>(
                client: client, tools: [], configuration: AgentConfiguration(maxIterations: 2)
            )
            let totals: TokenUsageTotals
            switch execution {
            case .blocking:
                let result = try await agent.run(userMessage: "Work", context: EmptyContext(), tokenBudget: 283)
                #expect(result.finishReason == .tokenBudgetExceeded(budget: 283, used: 284))
                #expect(result.iterations == 1)
                totals = result.totalTokenUsage
            case .streaming:
                var events: [StreamEvent.Kind] = []
                for try await event in agent.stream(userMessage: "Work", context: EmptyContext(), tokenBudget: 283) {
                    events.append(event.kind)
                }
                guard case let .finished(usage, _, reason, _) = events.last else {
                    Issue.record("Expected token budget termination")
                    return
                }
                #expect(reason == .tokenBudgetExceeded(budget: 283, used: 284))
                totals = usage
            }
            #expect(totals.input == 72)
            #expect(totals.output == 106)
            #expect(totals.reasoning == 106)
            #expect(totals.total == 284)
            #expect(totals.coverage == .complete)
            #expect(totals.cacheRead == 0)
            #expect(totals.cacheReadCoverage == .complete)
            #expect(totals.cacheWrite == nil)
            #expect(totals.cacheWriteCoverage == .unavailable)
        }
    }

    @Test
    func toolUseInputAdvancesAdvisoryAndPreservesAMeasurementGap() async throws {
        let response = #"{"candidates":[{"content":{"parts":[{"text":"Working"}]},"finishReason":"STOP"}],"#
            + #""usageMetadata":\#(GeminiUsageTestFixtures.toolUseMetadata)}"#
        let finish = #"{"candidates":[{"content":{"parts":[{"functionCall":{"id":"finish_1","#
            + #""name":"finish","args":{"content":"done"}}}]},"finishReason":"STOP"}]}"#
        try await withClient(responses: [response, finish], execution: .streaming) { client in
            let agent = Agent<EmptyContext>(client: client, tools: [], configuration: AgentConfiguration(
                maxIterations: 2, contextBudget: ContextBudgetConfig(softThreshold: 0.85)
            ))
            var events: [StreamEvent.Kind] = []
            var samples: [TokenUsage?] = []
            for try await event in agent.stream(userMessage: "Work", context: EmptyContext()) {
                events.append(event.kind)
                if case let .iterationCompleted(usage, _, _) = event.kind {
                    samples.append(usage)
                }
            }
            let budgets = events.compactMap { event -> ContextBudget? in
                guard case let .budgetUpdated(budget) = event else { return nil }
                return budget
            }
            let expectedBudget = ContextBudget(windowSize: 200, currentUsage: 178, softThreshold: 0.85)
            #expect(budgets == [expectedBudget])
            #expect(events.contains(.budgetAdvisory(budget: expectedBudget)))
            #expect(samples == [TokenUsage(input: 72, output: 106, reasoning: 106, cacheRead: 0), nil])
            guard case let .finished(totals, content, reason, _) = events.last else {
                Issue.record("Expected a finished Agent result")
                return
            }
            #expect(content == "done")
            #expect(reason == .completed)
            #expect(totals.input == 72)
            #expect(totals.output == 106)
            #expect(totals.reasoning == 106)
            #expect(totals.total == 284)
            #expect(totals.coverage == .partial)
            #expect(totals.cacheRead == 0)
            #expect(totals.cacheReadCoverage == .partial)
            #expect(totals.cacheWrite == nil)
            #expect(totals.cacheWriteCoverage == .unavailable)
        }
    }

    private func withClient(
        responses: [String], execution: Execution, operation: (VertexGoogleClient) async throws -> Void
    ) async throws {
        let session = URLSession(configuration: HTTPTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client = VertexGoogleClient(
            projectID: "usage-\(UUID().uuidString)", location: "us-central1", model: "gemini-2.5-pro",
            tokenProvider: { "test-token" }, contextWindowSize: 200, session: session, retryPolicy: .none
        )
        let request = try client.gemini.buildRequest(messages: [.user("Work")], tools: [])
        let urlRequest = try client.buildVertexURLRequest(request, stream: execution == .streaming, token: "test-token")
        let url = try #require(urlRequest.url)
        let sequence = HTTPTestResponseSequence(responses: responses.map { response in
            switch execution {
            case .blocking:
                HTTPTestResponse(body: Data(response.utf8))
            case .streaming:
                HTTPTestResponse(
                    body: Data("data: \(response)\n\n".utf8), headers: ["Content-Type": "text/event-stream"]
                )
            }
        })
        HTTPTestURLProtocol.register(url: url) { _ in try sequence.nextResponse(url: url) }
        defer { HTTPTestURLProtocol.unregister(url: url) }
        try await operation(client)
        #expect(HTTPTestURLProtocol.recordedBodyData(for: url).count == responses.count)
    }
}
