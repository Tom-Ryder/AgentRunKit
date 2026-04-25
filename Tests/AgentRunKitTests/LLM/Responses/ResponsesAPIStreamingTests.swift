@testable import AgentRunKit
import Foundation
import Testing

private func makeResponsesStreamingClient() -> ResponsesAPIClient {
    ResponsesAPIClient(
        apiKey: "test-key",
        model: "gpt-4.1",
        baseURL: ResponsesAPIClient.openAIBaseURL
    )
}

private let responsesStreamingEmptyCompletedJSON =
    #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","output":[],"#
        + #""usage":{"input_tokens":10,"output_tokens":5}}}"#

private let responsesCompletedWithReasoningJSON =
    #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","output":[],"#
        + #""usage":{"input_tokens":50,"output_tokens":30,"output_tokens_details":{"reasoning_tokens":10}}}}"#

private let responsesStreamingParityResponseJSON = """
{
    "id": "resp_parity",
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
            "content": [{"type": "output_text", "text": "Answer"}]
        },
        {
            "type": "function_call",
            "id": "fc_001",
            "status": "completed",
            "call_id": "call_1",
            "name": "search",
            "arguments": "{\\"q\\":\\"test\\"}"
        }
    ],
    "usage": {
        "input_tokens": 50,
        "output_tokens": 30,
        "output_tokens_details": {
            "reasoning_tokens": 10
        }
    }
}
"""

private let responsesStreamingParityCompletedJSON = """
{"type":"response.completed","response":\(responsesStreamingParityResponseJSON)}
"""

private let responsesToolCallOnlyResponseJSON = """
{
    "id": "resp_tools",
    "status": "completed",
    "output": [
        {
            "type": "function_call",
            "id": "fc_001",
            "status": "completed",
            "call_id": "call_1",
            "name": "search",
            "arguments": "{\\"q\\":\\"a\\"}"
        },
        {
            "type": "function_call",
            "id": "fc_002",
            "status": "completed",
            "call_id": "call_2",
            "name": "fetch",
            "arguments": "{\\"url\\":\\"https://example.com\\"}"
        }
    ],
    "usage": {
        "input_tokens": 20,
        "output_tokens": 10
    }
}
"""

private let responsesToolCallOnlyCompletedJSON = """
{"type":"response.completed","response":\(responsesToolCallOnlyResponseJSON)}
"""

private let responsesMultiPartReasoningResponseJSON = """
{
    "id": "resp_multi_rs",
    "status": "completed",
    "output": [
        {
            "type": "reasoning",
            "id": "rs_001",
            "status": "completed",
            "summary": [
                {"type": "summary_text", "text": "First thought"},
                {"type": "summary_text", "text": "Second thought"}
            ]
        },
        {
            "type": "message",
            "id": "msg_001",
            "status": "completed",
            "content": [{"type": "output_text", "text": "Result"}]
        }
    ],
    "usage": {
        "input_tokens": 50,
        "output_tokens": 30,
        "output_tokens_details": {
            "reasoning_tokens": 10
        }
    }
}
"""

private let responsesMultiPartReasoningCompletedJSON = """
{"type":"response.completed","response":\(responsesMultiPartReasoningResponseJSON)}
"""

private let responsesMultiItemReasoningResponseJSON = """
{
    "id": "resp_multi_item_rs",
    "status": "completed",
    "output": [
        {
            "type": "reasoning",
            "id": "rs_001",
            "status": "completed",
            "summary": [{"type": "summary_text", "text": "Step one"}]
        },
        {
            "type": "reasoning",
            "id": "rs_002",
            "status": "completed",
            "summary": [{"type": "summary_text", "text": "Step two"}]
        },
        {
            "type": "message",
            "id": "msg_001",
            "status": "completed",
            "content": [{"type": "output_text", "text": "Done"}]
        }
    ],
    "usage": {"input_tokens": 40, "output_tokens": 20, "output_tokens_details": {"reasoning_tokens": 8}}
}
"""

private let responsesMultiItemReasoningCompletedJSON = """
{"type":"response.completed","response":\(responsesMultiItemReasoningResponseJSON)}
"""

struct ResponsesStreamingTests {
    @Test
    func textDeltaYieldsContent() async throws {
        let lines = [
            responsesSSELine(#"{"type":"response.output_text.delta","delta":"Hello"}"#),
            responsesSSELine(#"{"type":"response.output_text.delta","delta":" world"}"#),
            responsesSSELine(
                #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","#
                    + #""output":[{"type":"message","content":[{"type":"output_text","text":"Hello world"}]}],"#
                    + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
            )
        ]
        let deltas = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)

        #expect(deltas.count == 3)
        #expect(deltas[0] == .content("Hello"))
        #expect(deltas[1] == .content(" world"))
        if case let .finished(usage) = deltas[2] {
            #expect(usage?.input == 10)
            #expect(usage?.output == 5)
        } else {
            Issue.record("Expected .finished")
        }
    }

    @Test
    func multilineSSEDataYieldsContent() async throws {
        let lines = [
            """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta",
            data: "delta":"Hello"}
            """,
            responsesSSELine(
                #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","#
                    + #""output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]}],"#
                    + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
            ),
        ]
        let deltas = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)

        #expect(deltas.first == .content("Hello"))
    }

    @Test
    func functionCallStartYieldsToolCallStart() async throws {
        let addedJSON =
            #"{"type":"response.output_item.added","output_index":0,"#
                + #""item":{"type":"function_call","call_id":"call_1","name":"search"}}"#
        let lines = [
            responsesSSELine(addedJSON),
            responsesSSELine(
                #"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"q\":"}"#
            ),
            responsesSSELine(
                #"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"\"test\"}"}"#
            ),
            responsesSSELine(
                #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","#
                    + #""output":[{"type":"function_call","call_id":"call_1","name":"search","#
                    + #""arguments":"{\"q\":\"test\"}"}],"#
                    + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
            )
        ]
        let deltas = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)

        #expect(deltas.count == 4)
        #expect(deltas[0] == .toolCallStart(index: 0, id: "call_1", name: "search", kind: .function))
        #expect(deltas[1] == .toolCallDelta(index: 0, arguments: "{\"q\":"))
        #expect(deltas[2] == .toolCallDelta(index: 0, arguments: "\"test\"}"))
    }

    @Test
    func customToolCallStreamYieldsCustomKindDeltas() async throws {
        let addedJSON =
            #"{"type":"response.output_item.added","output_index":0,"#
                + #""item":{"type":"custom_tool_call","call_id":"call_2","name":"calculator"}}"#
        let lines = [
            responsesSSELine(addedJSON),
            responsesSSELine(
                #"{"type":"response.custom_tool_call_input.delta","output_index":0,"delta":"2 + "}"#
            ),
            responsesSSELine(
                #"{"type":"response.custom_tool_call_input.delta","output_index":0,"delta":"3"}"#
            ),
            responsesSSELine(
                #"{"type":"response.completed","response":{"id":"resp_002","status":"completed","#
                    + #""output":[{"type":"custom_tool_call","call_id":"call_2","name":"calculator","#
                    + #""input":"2 + 3"}],"#
                    + #""usage":{"input_tokens":4,"output_tokens":2}}}"#
            )
        ]
        let deltas = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)

        #expect(deltas.count == 4)
        #expect(deltas[0] == .toolCallStart(index: 0, id: "call_2", name: "calculator", kind: .custom))
        #expect(deltas[1] == .toolCallDelta(index: 0, arguments: "2 + "))
        #expect(deltas[2] == .toolCallDelta(index: 0, arguments: "3"))
    }

    @Test
    func customToolCallReachesAssistantMessageAsCustomKind() async throws {
        let lines = [
            responsesSSELine(
                #"{"type":"response.completed","response":{"id":"resp_003","status":"completed","#
                    + #""output":[{"type":"custom_tool_call","call_id":"call_3","name":"shell","#
                    + #""input":"ls -la"}],"#
                    + #""usage":{"input_tokens":4,"output_tokens":3}}}"#
            )
        ]
        let elements = try await collectRunStreamElements(
            client: makeResponsesStreamingClient(),
            lines: lines
        )

        let toolCallStart = elements.compactMap { element -> StreamDelta? in
            if case let .delta(delta) = element { return delta }
            return nil
        }.first { delta in
            if case .toolCallStart = delta { return true }
            return false
        }
        guard case let .toolCallStart(_, id, name, kind) = try #require(toolCallStart) else {
            Issue.record("Expected toolCallStart delta for custom_tool_call")
            return
        }
        #expect(id == "call_3")
        #expect(name == "shell")
        #expect(kind == .custom)
    }

    @Test
    func mcpCallStreamingThrowsFeatureUnsupported() async throws {
        let lines = [
            responsesSSELine(
                #"{"type":"response.output_item.added","output_index":0,"#
                    + #""item":{"type":"mcp_call","call_id":"call_4","name":"fs.read"}}"#
            )
        ]
        await #expect {
            _ = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)
        } throws: { error in
            guard case let AgentError.llmError(inner) = error,
                  case let .featureUnsupported(provider, feature) = inner
            else { return false }
            return provider == "responses" && feature.contains("mcp_call")
        }
    }

    @Test
    func completedEventYieldsFinished() async throws {
        let lines = [responsesSSELine(responsesCompletedWithReasoningJSON)]
        let deltas = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)

        #expect(deltas.count == 1)
        if case let .finished(usage) = deltas[0] {
            #expect(usage == TokenUsage(input: 50, output: 20, reasoning: 10))
        } else {
            Issue.record("Expected .finished")
        }
    }

    @Test
    func completedEventYieldsFinalizedContinuity() async throws {
        let client = makeResponsesStreamingClient()
        let elements = try await collectRunStreamElements(
            client: client,
            lines: [responsesSSELine(responsesStreamingParityCompletedJSON)]
        )

        #expect(elements.count == 7)
        guard case let .finalizedContinuity(continuity) = try #require(elements.first(where: { element in
            if case .finalizedContinuity = element {
                return true
            }
            return false
        })) else {
            Issue.record("Expected finalized continuity")
            return
        }
        #expect(continuity.substrate == .responses)
        guard case let .object(payload) = continuity.payload,
              case let .array(output) = payload["output"]
        else {
            Issue.record("Expected Responses continuity payload")
            return
        }
        #expect(output.count == 3)
        if case let .object(item) = output[0] {
            #expect(item["type"] == .string("reasoning"))
        } else {
            Issue.record("Expected reasoning object")
        }
        if case let .object(item) = output[1] {
            #expect(item["type"] == .string("message"))
        } else {
            Issue.record("Expected message object")
        }
        if case let .object(item) = output[2] {
            #expect(item["type"] == .string("function_call"))
        } else {
            Issue.record("Expected function call object")
        }
        guard case let .delta(.finished(usage)) = try #require(elements.last) else {
            Issue.record("Expected finished delta")
            return
        }
        #expect(usage == TokenUsage(input: 50, output: 20, reasoning: 10))
    }

    @Test
    func completedStreamMatchesBlockingAtPersistedBoundaryWhenCompletedIsRicherThanDeltas() async throws {
        let client = makeResponsesStreamingClient()
        let response = try await client.decodeResponse(Data(responsesStreamingParityResponseJSON.utf8))
        let blockingAssistant = await client.parseResponse(response)
        let streamedAssistant = try await streamedAssistantMessage(
            client: client,
            lines: [
                responsesSSELine(#"{"type":"response.reasoning_summary_text.delta","delta":"Think"}"#),
                responsesSSELine(#"{"type":"response.output_text.delta","delta":"Ans"}"#),
                responsesSSELine(responsesStreamingParityCompletedJSON),
            ]
        )

        #expect(streamedAssistant.content == blockingAssistant.content)
        #expect(streamedAssistant.toolCalls == blockingAssistant.toolCalls)
        #expect(streamedAssistant.tokenUsage == blockingAssistant.tokenUsage)
        #expect(streamedAssistant.reasoning == blockingAssistant.reasoning)
        #expect(streamedAssistant.reasoningDetails == blockingAssistant.reasoningDetails)
        #expect(streamedAssistant.continuity == blockingAssistant.continuity)
    }

    @Test
    func completedStreamMatchesBlockingForToolCallOnlyResponse() async throws {
        let client = makeResponsesStreamingClient()
        let response = try await client.decodeResponse(Data(responsesToolCallOnlyResponseJSON.utf8))
        let blockingAssistant = await client.parseResponse(response)
        let streamedAssistant = try await streamedAssistantMessage(
            client: client,
            lines: [responsesSSELine(responsesToolCallOnlyCompletedJSON)]
        )

        #expect(streamedAssistant.content == blockingAssistant.content)
        #expect(streamedAssistant.toolCalls == blockingAssistant.toolCalls)
        #expect(streamedAssistant.tokenUsage == blockingAssistant.tokenUsage)
        #expect(streamedAssistant.reasoning == blockingAssistant.reasoning)
        #expect(streamedAssistant.reasoningDetails == blockingAssistant.reasoningDetails)
        #expect(streamedAssistant.continuity == blockingAssistant.continuity)
    }

    @Test
    func completedStreamMatchesBlockingForMultiPartReasoningSummary() async throws {
        let client = makeResponsesStreamingClient()
        let response = try await client.decodeResponse(Data(responsesMultiPartReasoningResponseJSON.utf8))
        let blockingAssistant = await client.parseResponse(response)
        let streamedAssistant = try await streamedAssistantMessage(
            client: client,
            lines: [
                responsesSSELine(
                    #"{"type":"response.reasoning_summary_text.delta","summary_index":0,"delta":"First thought"}"#
                ),
                responsesSSELine(
                    #"{"type":"response.reasoning_summary_text.delta","summary_index":1,"delta":"Second thought"}"#
                ),
                responsesSSELine(#"{"type":"response.output_text.delta","delta":"Result"}"#),
                responsesSSELine(responsesMultiPartReasoningCompletedJSON),
            ]
        )

        #expect(blockingAssistant.reasoning?.content == "First thought\nSecond thought")
        #expect(streamedAssistant.content == blockingAssistant.content)
        #expect(streamedAssistant.toolCalls == blockingAssistant.toolCalls)
        #expect(streamedAssistant.tokenUsage == blockingAssistant.tokenUsage)
        #expect(streamedAssistant.reasoning == blockingAssistant.reasoning)
        #expect(streamedAssistant.reasoningDetails == blockingAssistant.reasoningDetails)
        #expect(streamedAssistant.continuity == blockingAssistant.continuity)
    }

    @Test
    func completedStreamMatchesBlockingForMultiItemReasoningWithoutOutputIndex() async throws {
        let client = makeResponsesStreamingClient()
        let response = try await client.decodeResponse(Data(responsesMultiItemReasoningResponseJSON.utf8))
        let blockingAssistant = await client.parseResponse(response)
        let streamedAssistant = try await streamedAssistantMessage(
            client: client,
            lines: [
                responsesSSELine(
                    #"{"type":"response.reasoning_summary_text.delta","summary_index":0,"delta":"Step one"}"#
                ),
                responsesSSELine(
                    #"{"type":"response.reasoning_summary_text.delta","summary_index":0,"delta":"Step two"}"#
                ),
                responsesSSELine(#"{"type":"response.output_text.delta","delta":"Done"}"#),
                responsesSSELine(responsesMultiItemReasoningCompletedJSON),
            ]
        )

        #expect(blockingAssistant.reasoning?.content == "Step one\nStep two")
        #expect(streamedAssistant.reasoning == blockingAssistant.reasoning)
        #expect(streamedAssistant.content == blockingAssistant.content)
        #expect(streamedAssistant.continuity == blockingAssistant.continuity)
    }

    @Test
    func completedEventReconcilesMissingSemanticDeltasBeforeFinished() async throws {
        let deltas = try await collectResponsesStreamDeltas(
            client: makeResponsesStreamingClient(),
            lines: [
                responsesSSELine(#"{"type":"response.reasoning_summary_text.delta","delta":"Think"}"#),
                responsesSSELine(#"{"type":"response.output_text.delta","delta":"Ans"}"#),
                responsesSSELine(responsesStreamingParityCompletedJSON),
            ]
        )

        #expect(deltas.count == 8)
        #expect(deltas[0] == .reasoning("Think"))
        #expect(deltas[1] == .content("Ans"))
        #expect(deltas[2] == .reasoning("ing"))
        if case let .reasoningDetails(details) = deltas[3] {
            #expect(details.count == 1)
            if case let .object(object) = details[0] {
                #expect(object["type"] == .string("reasoning"))
            } else {
                Issue.record("Expected reasoning detail object")
            }
        } else {
            Issue.record("Expected reasoningDetails delta")
        }
        #expect(deltas[4] == .content("wer"))
        #expect(deltas[5] == .toolCallStart(index: 2, id: "call_1", name: "search", kind: .function))
        #expect(deltas[6] == .toolCallDelta(index: 2, arguments: #"{"q":"test"}"#))
        if case let .finished(usage) = deltas[7] {
            #expect(usage == TokenUsage(input: 50, output: 20, reasoning: 10))
        } else {
            Issue.record("Expected finished delta")
        }
    }

    @Test
    func completedEventReconcilesUnicodeFragmentsWithoutFalseDivergence() async throws {
        let completedJSON = """
        {
            "type": "response.completed",
            "response": {
                "id": "resp_unicode",
                "status": "completed",
                "output": [
                    {
                        "type": "message",
                        "content": [{"type": "output_text", "text": "👨‍👩‍👧‍👦 family"}]
                    }
                ],
                "usage": {"input_tokens": 10, "output_tokens": 5}
            }
        }
        """
        let deltas = try await collectResponsesStreamDeltas(
            client: makeResponsesStreamingClient(),
            lines: [
                responsesSSELine(#"{"type":"response.output_text.delta","delta":"👨"}"#),
                responsesSSELine(completedJSON),
            ]
        )

        #expect(deltas.count == 3)
        #expect(deltas[0] == .content("👨"))
        #expect(deltas[1] == .content("‍👩‍👧‍👦 family"))
        if case let .finished(usage) = deltas[2] {
            #expect(usage == TokenUsage(input: 10, output: 5))
        } else {
            Issue.record("Expected finished delta")
        }
    }

    @Test
    func completedEventSynthesesStartForDeltaBeforeStartToolCall() async throws {
        let completedJSON =
            #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","#
                + #""output":[{"type":"function_call","call_id":"call_1","name":"search","#
                + #""arguments":"{\"q\":\"test\"}"}],"#
                + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
        let deltas = try await collectResponsesStreamDeltas(
            client: makeResponsesStreamingClient(),
            lines: [
                responsesSSELine(
                    #"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"q\":"}"#
                ),
                responsesSSELine(completedJSON),
            ]
        )

        #expect(deltas[0] == .toolCallDelta(index: 0, arguments: #"{"q":"#))
        #expect(deltas[1] == .toolCallStart(index: 0, id: "call_1", name: "search", kind: .function))
        #expect(deltas[2] == .toolCallDelta(index: 0, arguments: #""test"}"#))
        if case .finished = deltas[3] {} else {
            Issue.record("Expected finished delta")
        }
    }
}

struct ResponsesStreamingFailureSafetyTests {
    @Test
    func completedEventThatContradictsEarlierSemanticDeltasThrowsAndDoesNotAdvanceCursor() async throws {
        let client = makeResponsesStreamingClient()
        await client.setLastResponseId("resp_prev")
        await client.setLastMessageCount(7)

        let result = await collectRunStreamElementsResult(
            client: client,
            lines: [
                responsesSSELine(#"{"type":"response.output_text.delta","delta":"Mismatch"}"#),
                responsesSSELine(responsesStreamingParityCompletedJSON),
            ]
        )

        #expect(result.elements.count == 1)
        let error = try #require(result.error)
        #expect(error as? AgentError == .malformedStream(.finalizedSemanticStateDiverged))
        #expect(await client.lastResponseId == "resp_prev")
        #expect(await client.lastMessageCount == 7)
    }

    @Test
    func incompleteStreamThrowsAndDoesNotAdvanceCursor() async throws {
        let client = makeResponsesStreamingClient()
        await client.setLastResponseId("resp_prev")
        await client.setLastMessageCount(7)

        let result = await collectRunStreamElementsResult(
            client: client,
            lines: [responsesSSELine(#"{"type":"response.output_text.delta","delta":"Hello"}"#)]
        )

        #expect(result.elements.count == 1)
        guard case let .delta(delta) = try #require(result.elements.first) else {
            Issue.record("Expected content delta before EOF")
            return
        }
        #expect(delta == .content("Hello"))
        let error = try #require(result.error as? AgentError)
        #expect(error == .malformedStream(.responsesStreamIncomplete))
        #expect(await client.lastResponseId == "resp_prev")
        #expect(await client.lastMessageCount == 7)
    }

    @Test
    func completedEventWithUnexpectedStatusThrowsAndDoesNotAdvanceCursor() async throws {
        let client = makeResponsesStreamingClient()
        let completedJSON =
            #"{"type":"response.completed","response":{"id":"resp_bad","status":"in_progress","output":[],"#
                + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
        await client.setLastResponseId("resp_prev")
        await client.setLastMessageCount(7)

        let result = await collectRunStreamElementsResult(
            client: client,
            lines: [responsesSSELine(completedJSON)]
        )
        #expect(result.elements.isEmpty)
        let error = try #require(result.error)
        guard case let AgentError.llmError(transportError) = error else {
            Issue.record("Expected AgentError.llmError, got \(error)")
            return
        }
        guard case let .other(message) = transportError else {
            Issue.record("Expected TransportError.other, got \(transportError)")
            return
        }
        #expect(message.contains("Unexpected Responses status"))
        #expect(await client.lastResponseId == "resp_prev")
        #expect(await client.lastMessageCount == 7)
    }

    @Test
    func completedEventWithFailedStatusAndErrorThrowsAndDoesNotAdvanceCursor() async throws {
        let client = makeResponsesStreamingClient()
        let completedJSON =
            #"{"type":"response.completed","response":{"id":"resp_bad","status":"failed","output":[],"#
                + #""error":{"code":"server_error","message":"Internal error"},"#
                + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
        await client.setLastResponseId("resp_prev")
        await client.setLastMessageCount(7)

        let result = await collectRunStreamElementsResult(
            client: client,
            lines: [responsesSSELine(completedJSON)]
        )
        #expect(result.elements.isEmpty)
        let error = try #require(result.error)
        guard case let AgentError.llmError(transportError) = error else {
            Issue.record("Expected AgentError.llmError, got \(error)")
            return
        }
        guard case let .other(message) = transportError else {
            Issue.record("Expected TransportError.other, got \(transportError)")
            return
        }
        #expect(message.contains("server_error"))
        #expect(await client.lastResponseId == "resp_prev")
        #expect(await client.lastMessageCount == 7)
    }

    @Test
    func completedEventMissingOutputThrowsAndDoesNotAdvanceCursor() async throws {
        let client = makeResponsesStreamingClient()
        let completedJSON =
            #"{"type":"response.completed","response":{"id":"resp_bad","status":"completed","#
                + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
        let lines = [
            responsesSSELine(completedJSON)
        ]

        await client.setLastResponseId("resp_prev")
        await client.setLastMessageCount(7)

        let result = await collectRunStreamElementsResult(client: client, lines: lines)
        #expect(result.elements.isEmpty)
        let error = try #require(result.error)
        guard case let AgentError.llmError(transportError) = error else {
            Issue.record("Expected AgentError.llmError, got \(error)")
            return
        }
        guard case let .decodingFailed(description) = transportError else {
            Issue.record("Expected decodingFailed transport error, got \(transportError)")
            return
        }
        #expect(description.contains("output"))

        #expect(await client.lastResponseId == "resp_prev")
        #expect(await client.lastMessageCount == 7)
    }

    @Test
    func completedEventMalformedOutputTextThrowsAndDoesNotAdvanceCursor() async throws {
        let client = makeResponsesStreamingClient()
        let completedJSON =
            #"{"type":"response.completed","response":{"id":"resp_bad","status":"completed","#
                + #""output":[{"type":"message","content":[{"type":"output_text","text":123}]}],"#
                + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
        let lines = [
            responsesSSELine(completedJSON)
        ]

        await client.setLastResponseId("resp_prev")
        await client.setLastMessageCount(7)

        let result = await collectRunStreamElementsResult(client: client, lines: lines)
        #expect(result.elements.isEmpty)
        let error = try #require(result.error)
        guard case let AgentError.llmError(transportError) = error else {
            Issue.record("Expected AgentError.llmError, got \(error)")
            return
        }
        guard case let .decodingFailed(description) = transportError else {
            Issue.record("Expected decodingFailed transport error, got \(transportError)")
            return
        }
        #expect(description.contains("text"))

        #expect(await client.lastResponseId == "resp_prev")
        #expect(await client.lastMessageCount == 7)
    }

    @Test
    func unknownEventsIgnored() async throws {
        let lines = [
            responsesSSELine(#"{"type":"response.created","response":{}}"#),
            responsesSSELine(#"{"type":"response.in_progress"}"#),
            responsesSSELine(#"{"type":"response.output_text.delta","delta":"Hi"}"#),
            responsesSSELine(
                #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","#
                    + #""output":[{"type":"message","content":[{"type":"output_text","text":"Hi"}]}],"#
                    + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
            )
        ]
        let deltas = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)

        #expect(deltas.count == 2)
        #expect(deltas[0] == .content("Hi"))
    }

    @Test
    func failedEventThrowsError() async throws {
        let failedJSON = """
        {"type":"response.failed","response":{"error":{"message":"Rate limit exceeded","code":"rate_limit"}}}
        """
        let lines = [responsesSSELine(failedJSON)]

        do {
            _ = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error else {
                Issue.record("Expected llmError, got \(error)")
                return
            }
            if case let .other(message) = transport {
                #expect(message.contains("Rate limit"))
            } else {
                Issue.record("Expected .other, got \(transport)")
            }
        }
    }
}

struct ResponsesStreamingReasoningDetailTests {
    @Test
    func reasoningSummaryDeltaYieldsReasoning() async throws {
        let lines = [
            responsesSSELine(#"{"type":"response.reasoning_summary_text.delta","delta":"Thinking..."}"#),
            responsesSSELine(
                #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","#
                    + #""output":[{"type":"reasoning","id":"rs_001","summary":[{"type":"summary_text","#
                    + #""text":"Thinking..."}]}],"#
                    + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
            )
        ]
        let deltas = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)

        #expect(deltas.count == 3)
        #expect(deltas[0] == .reasoning("Thinking..."))
        if case let .reasoningDetails(details) = deltas[1] {
            #expect(details.count == 1)
        } else {
            Issue.record("Expected reasoningDetails delta")
        }
    }

    @Test
    func reasoningOutputItemDoneYieldsReasoningDetails() async throws {
        let doneJSON = """
        {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_001","summary_text":"Plan"}}
        """
        let lines = [
            responsesSSELine(doneJSON),
            responsesSSELine(
                #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","#
                    + #""output":[{"type":"reasoning","id":"rs_001","summary_text":"Plan"}],"#
                    + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
            )
        ]
        let deltas = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)

        #expect(deltas.count == 2)
        if case let .reasoningDetails(details) = deltas[0] {
            #expect(details.count == 1)
            if case let .object(obj) = details[0] {
                #expect(obj["type"] == .string("reasoning"))
            } else {
                Issue.record("Expected object in reasoning details")
            }
        } else {
            Issue.record("Expected .reasoningDetails")
        }
    }

    @Test
    func unknownOutputItemDoneIsIgnored() async throws {
        let lines = [
            responsesSSELine(
                #"{"type":"response.output_item.done","item":{"type":"custom","id":"item_1","payload":"ignored"}}"#
            ),
            responsesSSELine(responsesStreamingEmptyCompletedJSON)
        ]
        let deltas = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)

        #expect(deltas.count == 1)
        if case let .finished(usage) = deltas[0] {
            #expect(usage == TokenUsage(input: 10, output: 5))
        } else {
            Issue.record("Expected .finished")
        }
    }

    @Test
    func unknownOutputItemDoneDoesNotBreakPersistedParity() async throws {
        let client = makeResponsesStreamingClient()
        let response = try await client.decodeResponse(Data(
            #"{"id":"resp_001","status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":5}}"#
                .utf8
        ))
        let blockingAssistant = await client.parseResponse(response)
        let streamedAssistant = try await streamedAssistantMessage(
            client: client,
            lines: [
                responsesSSELine(
                    #"{"type":"response.output_item.done","item":{"type":"custom","id":"item_1","payload":"ignored"}}"#
                ),
                responsesSSELine(responsesStreamingEmptyCompletedJSON),
            ]
        )

        #expect(streamedAssistant.content == blockingAssistant.content)
        #expect(streamedAssistant.toolCalls == blockingAssistant.toolCalls)
        #expect(streamedAssistant.tokenUsage == blockingAssistant.tokenUsage)
        #expect(streamedAssistant.reasoning == blockingAssistant.reasoning)
        #expect(streamedAssistant.reasoningDetails == blockingAssistant.reasoningDetails)
        #expect(streamedAssistant.continuity == blockingAssistant.continuity)
    }
}

private func responsesSSELine(_ json: String) -> String {
    "data: \(json.replacingOccurrences(of: "\n", with: ""))"
}

private func collectResponsesStreamDeltas(
    client: ResponsesAPIClient,
    lines: [String]
) async throws -> [StreamDelta] {
    var collected: [StreamDelta] = []
    for element in try await collectRunStreamElements(client: client, lines: lines) {
        guard case let .delta(delta) = element else { continue }
        collected.append(delta)
    }
    return collected
}

private func streamedAssistantMessage(
    client: ResponsesAPIClient,
    lines: [String]
) async throws -> AssistantMessage {
    let elements = try await collectRunStreamElements(client: client, lines: lines)
    let streamClient = ContinuityStreamingMockLLMClient(streamSequences: [elements])
    let processor = StreamProcessor(
        client: streamClient, toolDefinitions: [], policy: .chat,
        eventFactory: StreamEventFactory(sessionID: nil, runID: nil, origin: .live)
    )
    let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
    var totalUsage = TokenUsage()

    let iteration = try await processor.process(
        messages: [.user("Hi")],
        totalUsage: &totalUsage,
        continuation: continuation
    )
    return iteration.toAssistantMessage()
}

private func collectRunStreamElements(
    client: ResponsesAPIClient,
    lines: [String]
) async throws -> [RunStreamElement] {
    let result = await collectRunStreamElementsResult(client: client, lines: lines)
    if let error = result.error {
        throw error
    }
    return result.elements
}

private func collectRunStreamElementsResult(
    client: ResponsesAPIClient,
    lines: [String]
) async -> (elements: [RunStreamElement], error: (any Error)?) {
    let allBytes = lines.joined(separator: "\n\n").appending("\n\n")
    let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()
    for byte in Array(allBytes.utf8) {
        byteContinuation.yield(byte)
    }
    byteContinuation.finish()

    let controlled = ControlledByteStream(stream: byteStream)
    let streamPair = AsyncThrowingStream<RunStreamElement, Error>.makeStream()
    let task = Task {
        do {
            try await client.processRunStreamBytes(
                bytes: controlled,
                messagesCount: 0,
                stallTimeout: nil,
                continuation: streamPair.continuation
            )
        } catch {
            streamPair.continuation.finish(throwing: error)
        }
    }

    var elements: [RunStreamElement] = []
    do {
        for try await element in streamPair.stream {
            elements.append(element)
        }
        _ = await task.result
        return (elements, nil)
    } catch {
        _ = await task.result
        return (elements, error)
    }
}
