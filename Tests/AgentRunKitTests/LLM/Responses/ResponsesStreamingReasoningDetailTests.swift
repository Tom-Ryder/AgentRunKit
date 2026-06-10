@testable import AgentRunKit
import Foundation
import Testing

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
