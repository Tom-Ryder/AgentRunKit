@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesCrossConversationTests {
    @Test
    func sharedClientDoesNotReuseCursorAcrossConversations() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )

        let responseA = AssistantMessage(content: "Hi A")
        await client.setCursorState(
            responseId: "resp_A",
            messages: [.system("Assistant A"), .user("Hello A"), .assistant(responseA)]
        )

        let conversationB: [ChatMessage] = [
            .system("Assistant B"),
            .user("Hello B"),
            .assistant(AssistantMessage(content: "Hi B")),
            .user("Follow up B"),
        ]
        let request = try await client.buildRequest(messages: conversationB, tools: [])
        let json = try encodeRequest(request)

        #expect(json["previous_response_id"] == nil)
        #expect(json["instructions"] as? String == "Assistant B")
        #expect((json["input"] as? [[String: Any]])?.count == 3)
    }

    @Test
    func samePrefixContinuationUsesDeltaCorrectly() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )

        let initial: [ChatMessage] = [.system("Be helpful"), .user("Hello")]
        let priorResponse = AssistantMessage(content: "Hi")
        await client.setCursorState(
            responseId: "resp_001",
            messages: initial + [.assistant(priorResponse)]
        )

        let continued = initial + [
            .assistant(priorResponse),
            .tool(id: "call_1", name: "search", content: "result"),
        ]
        let request = try await client.buildRequest(messages: continued, tools: [])
        let json = try encodeRequest(request)

        #expect(json["previous_response_id"] as? String == "resp_001")
    }

    @Test
    func samePrefixDifferentAssistantTurnRejectsDelta() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )

        let prompt: [ChatMessage] = [.system("Be helpful"), .user("Hello")]
        let branchA = AssistantMessage(content: "Response from branch A")
        await client.setCursorState(
            responseId: "resp_A",
            messages: prompt + [.assistant(branchA)]
        )

        let branchB = AssistantMessage(content: "Response from branch B")
        let messagesFromB = prompt + [.assistant(branchB), .user("Follow up")]
        let request = try await client.buildRequest(messages: messagesFromB, tools: [])
        let json = try encodeRequest(request)

        #expect(json["previous_response_id"] == nil)
    }

    @Test
    func samePrefixDifferentToolCallsRejectsDelta() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )

        let prompt: [ChatMessage] = [.system("Be helpful"), .user("Search")]
        let callA = ToolCall(id: "call_A", name: "search", arguments: "{\"q\":\"alpha\"}")
        let branchA = AssistantMessage(content: "", toolCalls: [callA])
        await client.setCursorState(
            responseId: "resp_A",
            messages: prompt + [.assistant(branchA)]
        )

        let callB = ToolCall(id: "call_B", name: "search", arguments: "{\"q\":\"beta\"}")
        let branchB = AssistantMessage(content: "", toolCalls: [callB])
        let messagesFromB = prompt + [
            .assistant(branchB),
            .tool(id: "call_B", name: "search", content: "beta result"),
        ]
        let request = try await client.buildRequest(messages: messagesFromB, tools: [])
        let json = try encodeRequest(request)

        #expect(json["previous_response_id"] == nil)
    }

    @Test
    func samePrefixSameTextDifferentResponsesContinuityRejectsDelta() async throws {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )

        let prompt: [ChatMessage] = [.system("Be helpful"), .user("Hello")]
        let branchA = AssistantMessage(content: "Hi", continuity: stubContinuity(messageId: "msg_a"))
        let branchB = AssistantMessage(content: "Hi", continuity: stubContinuity(messageId: "msg_b"))
        #expect(
            client.prefixSignature(prompt + [.assistant(branchA)])
                != client.prefixSignature(prompt + [.assistant(branchB)])
        )

        await client.setCursorState(
            responseId: "resp_A",
            messages: prompt + [.assistant(branchA)]
        )

        let messagesFromB = prompt + [.assistant(branchB), .user("Follow up")]
        let request = try await client.buildRequest(messages: messagesFromB, tools: [])
        let json = try encodeRequest(request)

        #expect(json["previous_response_id"] == nil)
    }

    @Test
    func sharedClientGenerateDoesNotContaminateAcrossConversations() async throws {
        let baseURL = try #require(URL(string: "https://responses-cross-conv.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let responseSequence = ResponsesTestResponseSequence(
            payloads: [crossConvPayload(id: "resp_A", text: "Hi A"), crossConvPayload(id: "resp_B", text: "Hi B")]
        )

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            try responseSequence.nextResponse(url: requestURL)
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

        let responseA = try await client.generate(
            messages: [.system("A"), .user("Hello A")],
            tools: [],
            responseFormat: nil,
            requestContext: nil
        )
        #expect(responseA.content == "Hi A")

        let responseB = try await client.generate(
            messages: [.system("B"), .user("Hello B"), .user("More B")],
            tools: [],
            responseFormat: nil,
            requestContext: nil
        )
        #expect(responseB.content == "Hi B")

        let bodies = try ResponsesTestURLProtocol.recordedBodies(for: requestURL)
        #expect(bodies.count == 2)
        #expect(bodies[0]["previous_response_id"] == nil)
        #expect(bodies[1]["previous_response_id"] == nil)
        #expect(await client.lastResponseId == "resp_B")
    }

    @Test
    func sharedClientStreamingDoesNotContaminateAcrossConversations() async throws {
        let baseURL = try #require(URL(string: "https://responses-stream-cross-conv.test/v1"))
        let requestURL = baseURL.appendingPathComponent("responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let responseSequence = ResponsesTestResponseSequence(responses: [
            crossConvSSEResponse(id: "resp_A", text: "Hi A"),
            crossConvSSEResponse(id: "resp_B", text: "Hi B"),
        ])

        ResponsesTestURLProtocol.register(url: requestURL) { _ in
            try responseSequence.nextResponse(url: requestURL)
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

        let streamA = client.streamForRun(
            messages: [.system("A"), .user("Hello A")],
            tools: [],
            requestContext: nil,
            requestMode: .auto
        )
        for try await _ in streamA {}

        let streamB = client.streamForRun(
            messages: [.system("B"), .user("Hello B"), .user("More B")],
            tools: [],
            requestContext: nil,
            requestMode: .auto
        )
        for try await _ in streamB {}

        let bodies = try ResponsesTestURLProtocol.recordedBodies(for: requestURL)
        #expect(bodies.count == 2)
        #expect(bodies[0]["previous_response_id"] == nil)
        #expect(bodies[1]["previous_response_id"] == nil)
        #expect(await client.lastResponseId == "resp_B")
    }

    @Test
    func prefixSignatureDistinguishesDistinctConversations() {
        let client = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-4.1",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: true
        )
        let signatureA = client.prefixSignature([ChatMessage.system("A"), .user("Hello A")])
        let signatureB = client.prefixSignature([ChatMessage.system("B"), .user("Hello B")])
        let signatureC = client.prefixSignature([ChatMessage.system("A"), .user("Hello A"), .user("Extra")])
        let signatureEmpty = client.prefixSignature([ChatMessage]())

        #expect(signatureA != signatureB)
        #expect(signatureA != signatureC)
        #expect(signatureA != signatureEmpty)
        #expect(signatureB != signatureC)
    }
}

private func stubContinuity(messageId: String) -> AssistantContinuity {
    AssistantContinuity(
        substrate: .responses,
        payload: .object([
            "output": .array([
                .object([
                    "type": .string("message"),
                    "id": .string(messageId),
                    "status": .string("completed"),
                    "role": .string("assistant"),
                    "content": .array([.object(["type": .string("output_text"), "text": .string("Hi")])]),
                ]),
            ]),
        ])
    )
}

private func crossConvPayload(id: String, text: String) -> Data {
    Data("""
    {"id":"\(id)","status":"completed",\
    "output":[{"type":"message","content":[{"type":"output_text","text":"\(text)"}]}],\
    "usage":{"input_tokens":10,"output_tokens":5}}
    """.utf8)
}

private func crossConvSSEResponse(id: String, text: String) -> ResponsesTestHTTPResponse {
    let json = """
    {"type":"response.completed","response":{"id":"\(id)","status":"completed",\
    "output":[{"type":"message","content":[{"type":"output_text","text":"\(text)"}]}],\
    "usage":{"input_tokens":10,"output_tokens":5}}}
    """
    let sse = "data: \(json)\n\n"
    return ResponsesTestHTTPResponse(
        body: Data(sse.utf8),
        headers: ["Content-Type": "text/event-stream"]
    )
}
