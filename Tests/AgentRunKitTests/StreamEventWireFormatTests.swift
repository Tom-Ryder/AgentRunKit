@testable import AgentRunKit
import Foundation
import Testing

struct StreamEventWireFormatTests {
    private func fixedDate(millisecondsSince1970: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(millisecondsSince1970) / 1000)
    }

    private func uuid(_ string: String) throws -> UUID {
        try #require(UUID(uuidString: string))
    }

    @Test func finishedEventFixtureIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000101")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            sessionID: SessionID(rawValue: uuid("11111111-2222-3333-4444-555555555555")),
            runID: RunID(rawValue: uuid("66666666-7777-8888-9999-AAAAAAAAAAAA")),
            kind: .finished(
                tokenUsage: TokenUsage(input: 100, output: 50),
                content: "Done.",
                reason: .completed,
                history: []
            )
        )

        let data = try StreamEventJSONCodec.encode(event)
        let string = try #require(String(data: data, encoding: .utf8))

        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000101","#,
            #""kind":{"content":"Done.","history":[],"#,
            #""reason":{"type":"completed"},"#,
            #""tokenUsage":{"input":100,"output":50,"reasoning":0},"#,
            #""type":"finished"},"#,
            #""runID":"66666666-7777-8888-9999-AAAAAAAAAAAA","#,
            #""sessionID":"11111111-2222-3333-4444-555555555555","#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        #expect(string == expected)

        let decoded = try StreamEventJSONCodec.decode(data)
        #expect(decoded.id == event.id)
        #expect(decoded.timestamp == event.timestamp)
        #expect(decoded.sessionID == event.sessionID)
        #expect(decoded.runID == event.runID)
        #expect(decoded.parentEventID == nil)
        #expect(decoded.kind == event.kind)

        let reencoded = try StreamEventJSONCodec.encode(decoded)
        let reencodedString = try #require(String(data: reencoded, encoding: .utf8))
        #expect(reencodedString == string)
    }

    @Test func recursiveSubAgentEventFixtureIsStable() throws {
        let childEvent = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000202")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_456),
            kind: .delta("inner content")
        )
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000201")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .subAgentEvent(
                toolCallId: "tc_sub",
                toolName: "research",
                event: childEvent
            )
        )

        let data = try StreamEventJSONCodec.encode(event)
        let string = try #require(String(data: data, encoding: .utf8))
        let expected = [
            "{\"id\":\"00000000-0000-0000-0000-000000000201\",",
            "\"kind\":{\"event\":{\"id\":\"00000000-0000-0000-0000-",
            "000000000202\",\"kind\":{\"text\":\"inner content\",",
            "\"type\":\"delta\"},\"timestamp\":\"2026-03-30T14:",
            "22:07.456Z\"},\"toolCallId\":\"tc_sub\",",
            "\"toolName\":\"research\",\"type\":\"subAgentEvent\"",
            "},\"timestamp\":\"2026-03-30T14:22:07.123Z\"}",
        ].joined()

        #expect(
            string == expected
        )

        let decoded = try StreamEventJSONCodec.decode(data)
        guard case let .subAgentEvent(toolCallId, toolName, nestedEvent) = decoded.kind else {
            Issue.record("Expected subAgentEvent, got \(decoded.kind)")
            return
        }
        #expect(toolCallId == "tc_sub")
        #expect(toolName == "research")
        #expect(decoded.id == event.id)
        #expect(decoded.timestamp == event.timestamp)
        #expect(nestedEvent.id == childEvent.id)
        #expect(nestedEvent.timestamp == childEvent.timestamp)
        #expect(nestedEvent.kind == childEvent.kind)

        let reencoded = try StreamEventJSONCodec.encode(decoded)
        let reencodedString = try #require(String(data: reencoded, encoding: .utf8))
        #expect(reencodedString == string)
    }

    @Test func structuralFinishedEventFixtureIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000301")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_528_123),
            kind: .finished(
                tokenUsage: TokenUsage(input: 80, output: 20),
                content: nil,
                reason: .maxIterationsReached(limit: 3),
                history: []
            )
        )

        let data = try StreamEventJSONCodec.encode(event)
        let string = try #require(String(data: data, encoding: .utf8))
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000301","#,
            #""kind":{"history":[],"#,
            #""reason":{"limit":3,"type":"maxIterationsReached"},"#,
            #""tokenUsage":{"input":80,"output":20,"reasoning":0},"#,
            #""type":"finished"},"#,
            #""timestamp":"2026-03-30T14:22:08.123Z"}"#,
        ].joined()
        #expect(string == expected)

        let decoded = try StreamEventJSONCodec.decode(data)
        #expect(decoded.kind == event.kind)
    }
}
