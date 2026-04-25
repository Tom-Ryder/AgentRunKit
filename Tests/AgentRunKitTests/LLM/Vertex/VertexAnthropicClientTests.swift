@testable import AgentRunKit
import Foundation
import Testing

struct VertexAnthropicURLTests {
    private func makeClient(
        projectID: String = "test-project",
        location: String = "us-east5",
        model: String = "claude-sonnet-4-6",
        reasoningConfig: ReasoningConfig? = nil,
        anthropicReasoning: AnthropicReasoningOptions = .manual,
        interleavedThinking: Bool = true
    ) throws -> VertexAnthropicClient {
        try VertexAnthropicClient(
            projectID: projectID,
            location: location,
            model: model,
            tokenProvider: { "test-token-123" },
            reasoningConfig: reasoningConfig,
            anthropicReasoning: anthropicReasoning,
            interleavedThinking: interleavedThinking
        )
    }

    @Test
    func vertexURLHasCorrectPath() throws {
        let client = try makeClient()
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
        let client = try makeClient()
        let request = try client.anthropic.buildRequest(
            messages: [.user("Hi")], tools: [], stream: true
        )
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: true, token: "tok")

        #expect(urlRequest.url?.absoluteString.contains(":streamRawPredict") == true)
    }

    @Test
    func bearerTokenInAuthHeader() throws {
        let client = try makeClient()
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "my-oauth-token")

        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer my-oauth-token")
    }

    @Test
    func noApiKeyHeader() throws {
        let client = try makeClient()
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "tok")

        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == nil)
    }

    @Test
    func httpMethodIsPost() throws {
        let client = try makeClient()
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "tok")

        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func differentLocationsChangeHost() throws {
        let client = try makeClient(location: "europe-west4")
        let request = try client.anthropic.buildRequest(messages: [.user("Hi")], tools: [])
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "tok")

        #expect(urlRequest.url?.host == "europe-west4-aiplatform.googleapis.com")
        #expect(urlRequest.url?.absoluteString.contains("/locations/europe-west4/") == true)
    }

    @Test
    func betaHeaderWhenManualInterleavedThinking() throws {
        let client = try makeClient(reasoningConfig: .high, interleavedThinking: true)
        let request = try client.anthropic.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            transport: .vertex
        )
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "tok")

        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "interleaved-thinking-2025-05-14")
    }

    @Test
    func adaptiveThinkingDoesNotSendBetaHeader() throws {
        let client = try makeClient(
            reasoningConfig: .high,
            anthropicReasoning: .adaptive,
            interleavedThinking: true
        )
        let request = try client.anthropic.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            transport: .vertex
        )
        let wrapped = VertexAnthropicRequest(inner: request)
        let urlRequest = try client.buildVertexURLRequest(wrapped, stream: false, token: "tok")

        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }
}

struct VertexAnthropicRequestTests {
    @Test
    func requestBodyContainsAnthropicVersion() throws {
        let client = try VertexAnthropicClient(
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
        let client = try VertexAnthropicClient(
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
        let client = try VertexAnthropicClient(
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

    @Test
    func adaptiveThinkingPreservesOutputConfig() throws {
        let client = try VertexAnthropicClient(
            projectID: "p",
            location: "l",
            model: "claude-sonnet-4-6",
            tokenProvider: { "tok" },
            reasoningConfig: .xhigh,
            anthropicReasoning: .adaptive
        )
        let request = try client.anthropic.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            transport: .vertex
        )
        let wrapped = VertexAnthropicRequest(inner: request)
        let data = try JSONEncoder().encode(wrapped)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let thinking = json["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "adaptive")
        let outputConfig = json["output_config"] as? [String: Any]
        #expect(outputConfig?["effort"] as? String == "max")
    }

    @Test
    func manualInterleavedThinkingRejectsUnsupportedVertexModel() throws {
        let client = try VertexAnthropicClient(
            projectID: "p",
            location: "l",
            model: "claude-haiku-4-5@20251001",
            tokenProvider: { "tok" },
            reasoningConfig: .high,
            interleavedThinking: true
        )

        #expect(throws: AgentError.self) {
            _ = try client.anthropic.buildRequest(
                messages: [.user("Hi")],
                tools: [],
                transport: .vertex
            )
        }
    }
}

struct VertexAnthropicResponseTests {
    @Test
    func responseParsingDelegatedToAnthropic() throws {
        let client = try VertexAnthropicClient(
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
    func responseFormatEncodesThroughVertexRequest() throws {
        let client = try VertexAnthropicClient(
            projectID: "p", location: "l", model: "m",
            tokenProvider: { "tok" }
        )
        let format = ResponseFormat.jsonSchema(TestVertexAnthropicOutput.self)
        let request = try client.anthropic.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            transport: .vertex,
            responseFormat: format
        )
        let wrapped = VertexAnthropicRequest(inner: request)
        let data = try JSONEncoder().encode(wrapped)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outputConfig = try #require(json["output_config"] as? [String: Any])
        let formatJSON = try #require(outputConfig["format"] as? [String: Any])
        #expect(formatJSON["type"] as? String == "json_schema")
    }
}

struct VertexAnthropicContinuityTests {
    @Test
    func vertexBlockingParseMatchesDirectAnthropic() throws {
        let directClient = try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
        let vertexClient = try VertexAnthropicClient(
            projectID: "p", location: "l", model: "claude-sonnet-4-6",
            tokenProvider: { "tok" }
        )
        let json = """
        {
            "id": "msg_vertex",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "Planning", "signature": "sig_v"},
                {"type": "text", "text": "Result"},
                {"type": "tool_use", "id": "toolu_v1", "name": "lookup",
                 "input": {"id": 42}}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 100, "output_tokens": 80}
        }
        """
        let directMsg = try directClient.parseResponse(Data(json.utf8))
        let vertexMsg = try vertexClient.anthropic.parseResponse(Data(json.utf8))

        #expect(directMsg.continuity == vertexMsg.continuity)
        #expect(directMsg.content == vertexMsg.content)
        #expect(directMsg.toolCalls == vertexMsg.toolCalls)
        #expect(directMsg.reasoning == vertexMsg.reasoning)
    }

    @Test
    func vertexParseIncludesContinuity() throws {
        let client = try VertexAnthropicClient(
            projectID: "p", location: "l", model: "m",
            tokenProvider: { "tok" }
        )
        let json = """
        {
            "id": "msg_vc",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Vertex response"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 50, "output_tokens": 25}
        }
        """
        let msg = try client.anthropic.parseResponse(Data(json.utf8))
        #expect(msg.continuity?.substrate == .anthropicMessages)
    }
}

struct VertexAnthropicStreamingContinuityTests {
    private func sseLine(_ json: String) -> String {
        "data: \(json)"
    }

    @Test
    func vertexStreamingEmitsContinuityViaYieldPath() async throws {
        let vertexClient = try VertexAnthropicClient(
            projectID: "p", location: "l", model: "claude-sonnet-4-6",
            tokenProvider: { "tok" }
        )
        let lines = [
            sseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseLine(
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Vertex streaming"}}"#
            ),
            sseLine(#"{"type":"content_block_stop","index":0}"#),
            sseLine(#"{"type":"message_delta","usage":{"output_tokens":10}}"#),
            sseLine(#"{"type":"message_stop"}"#),
        ]
        let allBytes = lines.joined(separator: "\n\n").appending("\n\n")
        let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()
        for byte in Array(allBytes.utf8) {
            byteContinuation.yield(byte)
        }
        byteContinuation.finish()

        let controlled = ControlledByteStream(stream: byteStream)
        let state = AnthropicStreamState()
        let runPair = AsyncThrowingStream<RunStreamElement, Error>.makeStream()

        try await processSSEStream(
            bytes: controlled,
            stallTimeout: nil
        ) { event in
            try await vertexClient.anthropic.handleSSEEvent(event, state: state) { delta in
                _ = runPair.continuation.yield(.delta(delta))
            }
        }

        let blocks = try await state.finalizedBlocks()
        #expect(!blocks.isEmpty)
        let continuity = AnthropicTurnProjection(orderedBlocks: blocks).continuity
        #expect(continuity.substrate == .anthropicMessages)

        let blockingJSON = """
        {
            "id": "msg_vs",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Vertex streaming"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 50, "output_tokens": 10}
        }
        """
        let blockingMsg = try vertexClient.anthropic.parseResponse(Data(blockingJSON.utf8))
        #expect(continuity == blockingMsg.continuity)
    }
}

struct VertexAnthropicHistoryValidationTests {
    private let malformedHistory: [ChatMessage] = [
        .user("Hi"),
        .assistant(AssistantMessage(
            content: "",
            toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
        )),
    ]

    @Test
    func generateRejectsMalformedHistory() async throws {
        let client = try VertexAnthropicClient(
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
    func streamRejectsMalformedHistory() async throws {
        let client = try VertexAnthropicClient(
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

private enum TestVertexAnthropicOutput: SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: ["value": .string()], required: ["value"])
    }
}
