@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesOpaquePreservationTests {
    @Test
    func freshResponse_preservesUnknownTypeAsOpaque() throws {
        let raw: JSONValue = .object([
            "type": .string("custom_tool_call"),
            "call_id": .string("call_123"),
            "name": .string("grammar_query"),
            "input": .string("SELECT 1"),
        ])
        let item = try ResponsesOutputItem(raw)
        switch item {
        case let .opaque(value):
            #expect(value.raw == raw)
        default:
            Issue.record("expected opaque for custom_tool_call; got \(item)")
        }
    }

    @Test
    func replayState_roundTripsOpaqueAcrossContinuity() throws {
        let unknownItem: JSONValue = .object([
            "type": .string("mcp_call"),
            "server_label": .string("local-mcp"),
            "call_id": .string("call_mcp1"),
        ])
        let responseJSON: JSONValue = .object([
            "id": .string("resp_1"),
            "output": .array([
                .object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array([.object([
                        "type": .string("output_text"),
                        "text": .string("Hello"),
                    ])]),
                ]),
                unknownItem,
            ]),
        ])
        let data = try JSONEncoder().encode(responseJSON)
        let response = try JSONDecoder().decode(ResponsesAPIResponse.self, from: data)

        let state = ResponsesReplayState(response: response)
        #expect(state.output.count == 2)
        #expect(state.responseId == "resp_1")

        let continuity = state.continuity
        let rehydrated = try ResponsesReplayState(continuity: continuity)
        #expect(rehydrated.output.count == 2)
        #expect(rehydrated.responseId == "resp_1")

        let opaque = rehydrated.output[1]
        if case let .opaque(value) = opaque {
            #expect(value.raw == unknownItem)
        } else {
            Issue.record("opaque replay item not preserved across continuity")
        }
    }

    @Test
    func replayItemRehydrate_malformedKnownTypeStillThrows() throws {
        let malformed: JSONValue = .object([
            "type": .string("function_call"),
            "call_id": .string("call_x"),
        ])
        #expect(throws: AgentError.self) {
            _ = try ResponsesReplayItem(malformed)
        }
    }

    @Test
    func replayItemRehydrate_unknownTypeBecomesOpaque() throws {
        let raw: JSONValue = .object([
            "type": .string("apply_patch_call"),
            "call_id": .string("call_ap"),
        ])
        let item = try ResponsesReplayItem(raw)
        if case let .opaque(value) = item {
            #expect(value.raw == raw)
        } else {
            Issue.record("expected opaque for unknown type")
        }
    }
}
