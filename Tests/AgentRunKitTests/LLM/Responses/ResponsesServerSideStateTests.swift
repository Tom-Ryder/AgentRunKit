@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesServerSideStateTests {
    @Test
    func firstRequestSendsFullInputNoPreviousId() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )
        let messages: [ChatMessage] = [.system("Be helpful"), .user("Hello")]
        let request = try await client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(request)

        #expect(json["previous_response_id"] == nil)
        #expect(json["instructions"] as? String == "Be helpful")
        #expect((json["input"] as? [[String: Any]])?.count == 1)
    }

    @Test
    func afterResponseDeltaWithOnlyNewItems() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )

        let initial: [ChatMessage] = [.system("Be helpful"), .user("Hello")]
        let toolCall = ToolCall(id: "call_1", name: "search", arguments: "{}")
        let priorResponse = AssistantMessage(content: "", toolCalls: [toolCall])

        await client.setCursorState(
            responseId: "resp_001",
            messages: initial + [.assistant(priorResponse)]
        )

        let updated = initial + [
            .assistant(priorResponse),
            .tool(id: "call_1", name: "search", content: "result"),
        ]
        let request = try await client.buildRequest(messages: updated, tools: [])
        let json = try encodeRequest(request)

        #expect(json["previous_response_id"] as? String == "resp_001")
        #expect(json["instructions"] == nil)
        let input = json["input"] as? [[String: Any]]
        #expect(input?.count == 1)
        #expect(input?[0]["type"] as? String == "function_call_output")
    }

    @Test
    func truncatedHistoryBuildRequestDoesNotMutateState() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )

        await client.setLastResponseId("resp_001")
        await client.setLastMessageCount(5)
        await client.setLastPrefixSignature(Data([42]))

        let request = try await client.buildRequest(messages: [.user("Short")], tools: [])
        let json = try encodeRequest(request)

        #expect(json["previous_response_id"] == nil)
        #expect(await client.lastResponseId == "resp_001")
        #expect(await client.lastMessageCount == 5)
    }

    @Test
    func resetConversationClearsState() async {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )

        await client.setLastResponseId("resp_001")
        await client.setLastMessageCount(5)
        await client.setLastPrefixSignature(Data([42]))
        await client.resetConversation()

        #expect(await client.lastResponseId == nil)
        #expect(await client.lastMessageCount == 0)
        #expect(await client.lastPrefixSignature.isEmpty)
    }

    @Test
    func truncatedHistoryGenerateUsesFullRequestAndAdvancesCursor() async throws {
        let baseURL = try #require(URL(string: "https://responses-truncation-reset.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let responseJSON = """
        {
            "id": "resp_002",
            "status": "completed",
            "output": [{
                "type": "message",
                "content": [{"type": "output_text", "text": "Hello again"}]
            }],
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(responseJSON.utf8))
        }
        defer { ResponsesTestURLProtocol.unregister(url: requestURL) }

        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: baseURL,
            session: session,
            store: true
        )

        await client.setLastResponseId("resp_001")
        await client.setLastMessageCount(5)
        await client.setLastPrefixSignature(Data([42]))

        let response = try await client.generate(
            messages: [.user("Short")],
            tools: [],
            responseFormat: nil,
            requestContext: nil
        )

        #expect(response.content == "Hello again")
        let requestBody = try ResponsesTestURLProtocol.recordedBody(for: requestURL)
        #expect(requestBody["previous_response_id"] == nil)
        #expect(await client.lastResponseId == "resp_002")
        #expect(await client.lastMessageCount == 2)
    }

    @Test
    func rewrittenHistoryBypassesPreviousResponseId() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )
        let messages: [ChatMessage] = [
            .system("Be helpful"),
            .user("Hello"),
            .assistant(AssistantMessage(content: "Hi there")),
            .user("Follow up"),
        ]

        await client.setLastResponseId("resp_001")
        await client.setLastMessageCount(2)
        await client.setLastPrefixSignature(Data([42]))

        let request = try await client.buildRequest(
            messages: messages,
            tools: [],
            requestMode: .forceFullRequest
        )
        let json = try encodeRequest(request)

        #expect(json["previous_response_id"] == nil)
        #expect(json["instructions"] as? String == "Be helpful")
        #expect((json["input"] as? [[String: Any]])?.count == 3)
        #expect(await client.lastResponseId == "resp_001")
        #expect(await client.lastMessageCount == 2)
    }

    @Test
    func rewrittenHistoryGenerateUpdatesCursorAfterSuccess() async throws {
        let baseURL = try #require(URL(string: "https://responses-force-full-success.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let responseJSON = """
        {
            "id": "resp_002",
            "status": "completed",
            "output": [{
                "type": "message",
                "content": [{"type": "output_text", "text": "Hello again"}]
            }],
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(responseJSON.utf8))
        }
        defer { ResponsesTestURLProtocol.unregister(url: requestURL) }

        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: baseURL,
            session: session,
            store: true
        )
        let messages: [ChatMessage] = [
            .system("Be helpful"),
            .user("Hello"),
            .assistant(AssistantMessage(content: "Hi there")),
            .user("Follow up"),
        ]

        await client.setLastResponseId("resp_001")
        await client.setLastMessageCount(2)
        await client.setLastPrefixSignature(Data([42]))

        let response = try await client.generate(
            messages: messages,
            tools: [],
            responseFormat: nil,
            requestContext: nil,
            requestMode: .forceFullRequest
        )

        #expect(response.content == "Hello again")
        let requestBody = try ResponsesTestURLProtocol.recordedBody(for: requestURL)
        #expect(requestBody["previous_response_id"] == nil)
        #expect(requestBody["instructions"] as? String == "Be helpful")
        #expect(await client.lastResponseId == "resp_002")
        #expect(await client.lastMessageCount == messages.count + 1)
    }

    @Test
    func rewrittenHistoryBuildRequestPreservesRawResponsesReplayItems() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )
        let responseJSON = """
        {
            "id": "resp_002",
            "status": "completed",
            "output": [
                {
                    "type": "reasoning",
                    "id": "rs_001",
                    "status": "completed",
                    "summary": [{"type": "summary_text", "text": "Thinking"}]
                },
                {
                    "type": "message",
                    "id": "msg_001",
                    "status": "completed",
                    "content": [{"type": "output_text", "text": "Hello again"}]
                },
                {
                    "type": "function_call",
                    "id": "fc_001",
                    "status": "completed",
                    "call_id": "call_123",
                    "name": "search",
                    "arguments": "{\\"q\\":\\"test\\"}"
                }
            ],
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        let parsedResponse = try await client.decodeResponse(Data(responseJSON.utf8))
        let assistant = await client.parseResponse(parsedResponse)
        let messages: [ChatMessage] = [
            .system("Be helpful"),
            .assistant(assistant),
            .user("Follow up"),
        ]

        await client.setLastResponseId("resp_001")
        await client.setLastMessageCount(2)
        await client.setLastPrefixSignature(Data([42]))

        let request = try await client.buildRequest(
            messages: messages,
            tools: [],
            requestMode: .forceFullRequest
        )
        let json = try encodeRequest(request)
        let input = json["input"] as? [[String: Any]]

        #expect(json["previous_response_id"] == nil)
        #expect(input?.count == 4)
        #expect(input?[0]["type"] as? String == "reasoning")
        #expect(input?[0]["id"] as? String == "rs_001")
        #expect(input?[0]["status"] as? String == "completed")
        #expect(input?[1]["type"] as? String == "message")
        #expect(input?[1]["id"] as? String == "msg_001")
        #expect(input?[1]["status"] as? String == "completed")
        #expect(input?[1]["role"] as? String == "assistant")
        #expect(input?[2]["type"] as? String == "function_call")
        #expect(input?[2]["id"] as? String == "fc_001")
        #expect(input?[2]["status"] as? String == "completed")
        #expect(input?[3]["type"] as? String == "message")
        #expect(input?[3]["role"] as? String == "user")
        #expect(await client.lastResponseId == "resp_001")
        #expect(await client.lastMessageCount == 2)
    }

    @Test
    func rewrittenHistoryFailureCannotReuseStaleCursorWithoutCountShrink() async throws {
        let baseURL = try #require(URL(string: "https://responses-force-full-failure.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let failureBody = #"{"error":{"message":"upstream unavailable"}}"#

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(failureBody.utf8))
        }
        defer { ResponsesTestURLProtocol.unregister(url: requestURL) }

        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: baseURL,
            session: session,
            retryPolicy: .none,
            store: true
        )
        let messages: [ChatMessage] = [
            .system("Be helpful"),
            .user("Continue"),
        ]

        await client.setLastResponseId("resp_summary")
        await client.setLastMessageCount(messages.count)
        await client.setLastPrefixSignature(Data([42]))

        do {
            _ = try await client.generate(
                messages: messages,
                tools: [],
                responseFormat: nil,
                requestContext: nil,
                requestMode: .forceFullRequest
            )
            Issue.record("Expected forced full request failure")
        } catch let AgentError.llmError(transport) {
            #expect(transport == .httpError(statusCode: 500, body: failureBody))
        } catch {
            Issue.record("Expected AgentError.llmError, got \(error)")
        }

        let nextRequest = try await client.buildRequest(messages: messages, tools: [])
        let json = try encodeRequest(nextRequest)
        let failedRequest = try ResponsesTestURLProtocol.recordedBody(for: requestURL)
        #expect(failedRequest["previous_response_id"] == nil)
        #expect(json["previous_response_id"] == nil)
        #expect(await client.lastResponseId == nil)
        #expect(await client.lastMessageCount == 0)
    }

    @Test
    func malformedGenerateResponseDoesNotAdvanceDeltaCursor() async throws {
        let baseURL = try #require(URL(string: "https://responses-malformed-generate.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let malformedResponseJSON = """
        {
            "id": "resp_bad",
            "status": "completed",
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(malformedResponseJSON.utf8))
        }
        defer { ResponsesTestURLProtocol.unregister(url: requestURL) }

        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: baseURL,
            session: session,
            retryPolicy: .none,
            store: true
        )
        let priorInput: [ChatMessage] = [.user("Hello")]
        let priorResponse = AssistantMessage(content: "Hi there")
        await client.setCursorState(
            responseId: "resp_prev",
            messages: priorInput + [.assistant(priorResponse)]
        )

        let messages = priorInput + [.assistant(priorResponse), .user("Follow up")]

        await #expect(throws: AgentError.self) {
            _ = try await client.generate(
                messages: messages,
                tools: [],
                responseFormat: nil,
                requestContext: nil
            )
        }

        let requestBody = try ResponsesTestURLProtocol.recordedBody(for: requestURL)
        #expect(requestBody["previous_response_id"] as? String == "resp_prev")
        #expect(await client.lastResponseId == "resp_prev")
        #expect(await client.lastMessageCount == priorInput.count + 1)
    }
}

struct ResponsesStreamingCursorTests {
    @Test
    func streamingForceFullRequestBypassesStaleCursor() async throws {
        let baseURL = try #require(URL(string: "https://responses-stream-force.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let completedJSON = """
        {"type":"response.completed","response":{"id":"resp_002","status":"completed",\
        "output":[{"type":"message","content":[{"type":"output_text","text":"Hi"}]}],\
        "usage":{"input_tokens":10,"output_tokens":5}}}
        """
        let sseBody = "data: \(completedJSON)\n\n"

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            ))
            return (response, Data(sseBody.utf8))
        }
        defer { ResponsesTestURLProtocol.unregister(url: requestURL) }

        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: baseURL,
            session: session,
            retryPolicy: .none,
            store: true
        )

        await client.setLastResponseId("resp_001")
        await client.setLastMessageCount(5)
        await client.setLastPrefixSignature(Data([42]))

        let stream = client.streamForRun(
            messages: [.user("Hi")],
            tools: [],
            requestContext: nil,
            requestMode: .forceFullRequest
        )
        for try await _ in stream {}

        let requestBody = try ResponsesTestURLProtocol.recordedBody(for: requestURL)
        #expect(requestBody["previous_response_id"] == nil)
        #expect(await client.lastResponseId == "resp_002")
        #expect(await client.lastMessageCount == 2)
    }
}

struct ResponsesAgentRunRecoveryTests {
    @Test
    func rewrittenHistoryForcesFullRequestThenResumesDeltaMode() async throws {
        let baseURL = try #require(URL(string: "https://responses-agent.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let responseSequence = ResponsesTestResponseSequence(payloads: makeAgentRunRecoveryPayloads())

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            try responseSequence.nextResponse(url: requestURL)
        }
        defer { ResponsesTestURLProtocol.unregister(url: requestURL) }

        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            contextWindowSize: 1000,
            baseURL: baseURL,
            session: session,
            retryPolicy: .none,
            store: true
        )
        let noopTool = try Tool<ResponsesNoopParams, ResponsesNoopOutput, EmptyContext>(
            name: "noop",
            description: "Does nothing",
            executor: { _, _ in ResponsesNoopOutput() }
        )
        let agent = Agent<EmptyContext>(
            client: client,
            tools: [noopTool],
            configuration: AgentConfiguration(maxIterations: 4, compactionThreshold: 0.5)
        )

        let result = try await agent.run(userMessage: "Go", context: EmptyContext())

        #expect(try requireContent(result) == "done")
        #expect(result.iterations == 3)

        let bodies = try ResponsesTestURLProtocol.recordedBodies(for: requestURL)
        #expect(bodies.count == 4)
        #expect(bodies[0]["previous_response_id"] == nil)
        #expect(bodies[1]["previous_response_id"] as? String == "resp_turn1")
        #expect(bodies[2]["previous_response_id"] == nil)
        #expect(bodies[2]["instructions"] == nil)
        #expect((bodies[2]["input"] as? [[String: Any]])?.isEmpty == false)
        #expect(bodies[3]["previous_response_id"] as? String == "resp_turn2")
    }

    @Test
    func pruneRewriteForcesFullSummaryRequestBeforeMainRunRequest() async throws {
        let baseURL = try #require(URL(string: "https://responses-prune-summary.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let responseSequence = ResponsesTestResponseSequence(payloads: makePruneRewriteSummaryPayloads())

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            try responseSequence.nextResponse(url: requestURL)
        }
        defer { ResponsesTestURLProtocol.unregister(url: requestURL) }

        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            contextWindowSize: 1000,
            baseURL: baseURL,
            session: session,
            retryPolicy: .none,
            store: true
        )
        let noopTool = try Tool<ResponsesNoopParams, ResponsesNoopOutput, EmptyContext>(
            name: "noop",
            description: "Does nothing",
            executor: { _, _ in ResponsesNoopOutput() }
        )
        let agent = Agent<EmptyContext>(
            client: client,
            tools: [noopTool],
            configuration: AgentConfiguration(
                maxIterations: 4,
                compactionThreshold: 0.5,
                contextBudget: ContextBudgetConfig(enablePruneTool: true)
            )
        )

        let result = try await agent.run(userMessage: "Go", context: EmptyContext())

        #expect(try requireContent(result) == "done")
        #expect(result.iterations == 3)

        let bodies = try ResponsesTestURLProtocol.recordedBodies(for: requestURL)
        #expect(bodies.count == 4)
        #expect(bodies[0]["previous_response_id"] == nil)
        #expect(bodies[1]["previous_response_id"] as? String == "resp_turn1")
        #expect(bodies[2]["previous_response_id"] == nil)
        #expect((bodies[2]["input"] as? [[String: Any]])?.isEmpty == false)
        #expect(bodies[3]["previous_response_id"] == nil)
        #expect((bodies[3]["input"] as? [[String: Any]])?.isEmpty == false)
    }

    @Test
    func sameTurnPromptTooLongRecoveryForcesFullRetry() async throws {
        let baseURL = try #require(URL(string: "https://responses-prompt-too-long.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let responseSequence = ResponsesTestResponseSequence(responses: makePromptTooLongRecoveryResponses())

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            try responseSequence.nextResponse(url: requestURL)
        }
        defer { ResponsesTestURLProtocol.unregister(url: requestURL) }

        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            contextWindowSize: 1000,
            baseURL: baseURL,
            session: session,
            retryPolicy: .none,
            store: true
        )
        let blobTool = try Tool<ResponsesNoopParams, ResponsesBlobOutput, EmptyContext>(
            name: "blob",
            description: "Returns a large result",
            executor: { _, _ in ResponsesBlobOutput(blob: String(repeating: "x", count: 5000)) }
        )
        let agent = Agent<EmptyContext>(
            client: client,
            tools: [blobTool],
            configuration: AgentConfiguration(maxIterations: 3, compactionThreshold: 0.5)
        )

        let result = try await agent.run(userMessage: "Go", context: EmptyContext())

        #expect(try requireContent(result) == "done")
        #expect(result.iterations == 3)

        let bodies = try ResponsesTestURLProtocol.recordedBodies(for: requestURL)
        #expect(bodies.count == 4)
        #expect(bodies[0]["previous_response_id"] == nil)
        #expect(bodies[1]["previous_response_id"] as? String == "resp_turn1")
        #expect(bodies[2]["previous_response_id"] as? String == "resp_turn2")
        #expect(bodies[3]["previous_response_id"] == nil)
        #expect((bodies[3]["input"] as? [[String: Any]])?.isEmpty == false)
    }
}

struct ResponsesMultiTurnRoundTripTests {
    @Test
    func fullMultiTurnConversationWithToolRoundTrip() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )

        let turn1Messages: [ChatMessage] = [
            .system("You are a helpful assistant."),
            .user("What is the weather in NYC?"),
        ]
        let turn1Request = try await client.buildRequest(messages: turn1Messages, tools: [
            ToolDefinition(
                name: "get_weather",
                description: "Get weather",
                parametersSchema: .object(properties: ["city": .string()], required: ["city"])
            ),
        ])

        let turn1Json = try encodeRequest(turn1Request)
        #expect(turn1Json["previous_response_id"] == nil)
        #expect(turn1Json["instructions"] as? String == "You are a helpful assistant.")

        let toolCall = ToolCall(id: "call_weather", name: "get_weather", arguments: "{\"city\":\"NYC\"}")
        let turn1Response = AssistantMessage(content: "", toolCalls: [toolCall])
        await client.setCursorState(
            responseId: "resp_turn1",
            messages: turn1Messages + [.assistant(turn1Response)]
        )

        let turn2Messages = turn1Messages + [
            .assistant(AssistantMessage(content: "", toolCalls: [toolCall])),
            .tool(id: "call_weather", name: "get_weather", content: "{\"temp\":72}"),
        ]
        let turn2Request = try await client.buildRequest(messages: turn2Messages, tools: [
            ToolDefinition(
                name: "get_weather",
                description: "Get weather",
                parametersSchema: .object(properties: ["city": .string()], required: ["city"])
            ),
        ])

        let turn2Json = try encodeRequest(turn2Request)
        #expect(turn2Json["previous_response_id"] as? String == "resp_turn1")
        let turn2Input = turn2Json["input"] as? [[String: Any]]
        #expect(turn2Input?.count == 1)
        #expect(turn2Input?[0]["type"] as? String == "function_call_output")
        #expect(turn2Input?[0]["call_id"] as? String == "call_weather")
    }
}

private struct ResponsesNoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct ResponsesNoopOutput: Codable {}

private struct ResponsesBlobOutput: Codable {
    let blob: String
}

private func makeAgentRunRecoveryPayloads() -> [Data] {
    [
        #"""
        {
            "id": "resp_turn1",
            "status": "completed",
            "output": [
                {"type": "function_call", "call_id": "call_1", "name": "noop", "arguments": "{}"}
            ],
            "usage": {"input_tokens": 900, "output_tokens": 10}
        }
        """#,
        #"""
        {
            "id": "resp_summary",
            "status": "completed",
            "output": [
                {"type": "message", "content": [{"type": "output_text", "text": "Summary checkpoint"}]}
            ],
            "usage": {"input_tokens": 20, "output_tokens": 5}
        }
        """#,
        #"""
        {
            "id": "resp_turn2",
            "status": "completed",
            "output": [
                {"type": "function_call", "call_id": "call_2", "name": "noop", "arguments": "{}"}
            ],
            "usage": {"input_tokens": 100, "output_tokens": 10}
        }
        """#,
        #"""
        {
            "id": "resp_turn3",
            "status": "completed",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "finish_1",
                    "name": "finish",
                    "arguments": "{\"content\":\"done\"}"
                }
            ],
            "usage": {"input_tokens": 80, "output_tokens": 10}
        }
        """#,
    ].map { Data($0.utf8) }
}

private func makePruneRewriteSummaryPayloads() -> [Data] {
    [
        #"""
        {
            "id": "resp_turn1",
            "status": "completed",
            "output": [
                {"type": "function_call", "call_id": "call_1", "name": "noop", "arguments": "{}"}
            ],
            "usage": {"input_tokens": 100, "output_tokens": 10}
        }
        """#,
        #"""
        {
            "id": "resp_turn2",
            "status": "completed",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "prune_1",
                    "name": "prune_context",
                    "arguments": "{\"tool_call_ids\":[\"call_1\"]}"
                }
            ],
            "usage": {"input_tokens": 900, "output_tokens": 10}
        }
        """#,
        #"""
        {
            "id": "resp_summary",
            "status": "completed",
            "output": [
                {"type": "message", "content": [{"type": "output_text", "text": "Summary checkpoint"}]}
            ],
            "usage": {"input_tokens": 20, "output_tokens": 5}
        }
        """#,
        #"""
        {
            "id": "resp_turn3",
            "status": "completed",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "finish_1",
                    "name": "finish",
                    "arguments": "{\"content\":\"done\"}"
                }
            ],
            "usage": {"input_tokens": 80, "output_tokens": 10}
        }
        """#,
    ].map { Data($0.utf8) }
}

private func makePromptTooLongRecoveryResponses() -> [ResponsesTestHTTPResponse] {
    [
        ResponsesTestHTTPResponse(body: Data(#"""
        {
            "id": "resp_turn1",
            "status": "completed",
            "output": [
                {"type": "function_call", "call_id": "call_1", "name": "blob", "arguments": "{}"}
            ],
            "usage": {"input_tokens": 100, "output_tokens": 10}
        }
        """#.utf8)),
        ResponsesTestHTTPResponse(body: Data(#"""
        {
            "id": "resp_turn2",
            "status": "completed",
            "output": [
                {
                    "type": "message",
                    "content": [{"type": "output_text", "text": "Working state"}]
                }
            ],
            "usage": {"input_tokens": 80, "output_tokens": 10}
        }
        """#.utf8)),
        ResponsesTestHTTPResponse(statusCode: 400, body: Data(#"""
        {
            "error": {
                "message": "This model's maximum context length is 8 tokens.",
                "code": "context_length_exceeded"
            }
        }
        """#.utf8)),
        ResponsesTestHTTPResponse(body: Data(#"""
        {
            "id": "resp_turn3",
            "status": "completed",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "finish_1",
                    "name": "finish",
                    "arguments": "{\"content\":\"done\"}"
                }
            ],
            "usage": {"input_tokens": 80, "output_tokens": 10}
        }
        """#.utf8)),
    ]
}
