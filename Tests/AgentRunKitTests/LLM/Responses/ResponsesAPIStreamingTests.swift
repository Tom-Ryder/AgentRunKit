@testable import AgentRunKit
import Foundation
import Testing

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
        guard case let .llmError(.streamFailed(.malformedStream(reason, diagnostics))) = error as? AgentError else {
            Issue.record("Expected malformed stream, got \(error)")
            return
        }
        #expect(reason == .finalizedSemanticStateDiverged)
        #expect(diagnostics.eventsObserved == 2)
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
        guard case let .llmError(.streamFailed(.providerTerminationMissing(diagnostics))) = error else {
            Issue.record("Expected provider termination missing, got \(error)")
            return
        }
        #expect(diagnostics.eventsObserved == 1)
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
        guard case let .providerError(provider, code, message) = transportError else {
            Issue.record("Expected TransportError.providerError, got \(transportError)")
            return
        }
        #expect(provider == .openAIResponses)
        #expect(code == "server_error")
        #expect(message == "Internal error")
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
            if case let .streamFailed(.providerError(code, message, diagnostics)) = transport {
                #expect(diagnostics.provider == .openAIResponses)
                #expect(code == "rate_limit")
                #expect(message.contains("Rate limit"))
            } else {
                Issue.record("Expected providerError, got \(transport)")
            }
        }
    }

    @Test
    func failedEventWithoutPayloadThrowsProviderError() async throws {
        let lines = [responsesSSELine(#"{"type":"response.failed","response":{}}"#)]

        do {
            _ = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.providerError(code, message, _))) = error else {
                Issue.record("Expected providerError, got \(error)")
                return
            }
            #expect(code == nil)
            #expect(message == "Response failed without an error payload")
        }
    }

    @Test
    func errorEventThrowsProviderError() async throws {
        let lines = [responsesSSELine(#"{"type":"error","code":"server_error","message":"boom"}"#)]

        do {
            _ = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.providerError(code, message, diagnostics))) = error else {
                Issue.record("Expected providerError, got \(error)")
                return
            }
            #expect(code == "server_error")
            #expect(message == "boom")
            #expect(diagnostics.provider == .openAIResponses)
        }
    }

    @Test
    func responseErrorEventThrowsProviderError() async throws {
        let lines = [
            responsesSSELine(#"{"type":"response.error","error":{"code":"rate_limit","message":"slow down"}}"#),
        ]

        do {
            _ = try await collectResponsesStreamDeltas(client: makeResponsesStreamingClient(), lines: lines)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.providerError(code, message, _))) = error else {
                Issue.record("Expected providerError, got \(error)")
                return
            }
            #expect(code == "rate_limit")
            #expect(message == "slow down")
        }
    }

    @Test
    func incompleteEventCompletesWithPartialOutput() async throws {
        let incompleteJSON = #"{"type":"response.incomplete","response":{"id":"resp_inc","status":"incomplete","#
            + #""output":[{"type":"message","id":"msg_001","status":"incomplete","#
            + #""content":[{"type":"output_text","text":"Partial answer"}]}],"#
            + #""usage":{"input_tokens":10,"output_tokens":5}}}"#
        let deltas = try await collectResponsesStreamDeltas(
            client: makeResponsesStreamingClient(),
            lines: [responsesSSELine(incompleteJSON)]
        )

        #expect(deltas.contains(.content("Partial answer")))
        #expect(deltas.contains(.finished(usage: TokenUsage(input: 10, output: 5))))
    }
}
