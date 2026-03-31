@testable import AgentRunKit
import Foundation
import Testing

struct StreamEventKindCodableTests {
    private func roundTrip(_ kind: StreamEvent.Kind) throws -> StreamEvent.Kind {
        let event = StreamEvent(kind: kind)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)
        return decoded.kind
    }

    @Test func deltaRoundTrips() throws {
        let kind = StreamEvent.Kind.delta("Hello, world!")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func reasoningDeltaRoundTrips() throws {
        let kind = StreamEvent.Kind.reasoningDelta("Let me think...")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func toolCallStartedRoundTrips() throws {
        let kind = StreamEvent.Kind.toolCallStarted(name: "search", id: "tc_001")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func toolCallCompletedRoundTrips() throws {
        let kind = StreamEvent.Kind.toolCallCompleted(
            id: "tc_001",
            name: "search",
            result: ToolResult(content: "42 results found")
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func audioDataRoundTrips() throws {
        let kind = StreamEvent.Kind.audioData(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(try roundTrip(kind) == kind)
    }

    @Test func audioTranscriptRoundTrips() throws {
        let kind = StreamEvent.Kind.audioTranscript("Hello from audio")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func audioFinishedRoundTrips() throws {
        let kind = StreamEvent.Kind.audioFinished(
            id: "audio_001",
            expiresAt: 1_711_800_000,
            data: Data([0x01, 0x02, 0x03])
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func finishedRoundTrips() throws {
        let kind = StreamEvent.Kind.finished(
            tokenUsage: TokenUsage(input: 100, output: 50),
            content: "Done.",
            reason: .completed,
            history: []
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func finishedWithMaxIterationsReasonRoundTrips() throws {
        let kind = StreamEvent.Kind.finished(
            tokenUsage: TokenUsage(input: 20, output: 10),
            content: nil,
            reason: .maxIterationsReached(limit: 4),
            history: []
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func finishedWithTokenBudgetReasonRoundTrips() throws {
        let kind = StreamEvent.Kind.finished(
            tokenUsage: TokenUsage(input: 30, output: 20),
            content: nil,
            reason: .tokenBudgetExceeded(budget: 40, used: 50),
            history: []
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func subAgentStartedRoundTrips() throws {
        let kind = StreamEvent.Kind.subAgentStarted(toolCallId: "tc_sub", toolName: "research")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func subAgentEventRoundTrips() throws {
        let inner = StreamEvent(kind: .delta("inner content"))
        let kind = StreamEvent.Kind.subAgentEvent(toolCallId: "tc_sub", toolName: "research", event: inner)
        #expect(try roundTrip(kind) == kind)
    }

    @Test func subAgentCompletedRoundTrips() throws {
        let kind = StreamEvent.Kind.subAgentCompleted(
            toolCallId: "tc_sub",
            toolName: "research",
            result: ToolResult(content: "sub-agent result")
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func iterationCompletedRoundTrips() throws {
        let kind = StreamEvent.Kind.iterationCompleted(
            usage: TokenUsage(input: 200, output: 80, reasoning: 10),
            iteration: 3
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func compactedRoundTrips() throws {
        let kind = StreamEvent.Kind.compacted(totalTokens: 5000, windowSize: 8192)
        #expect(try roundTrip(kind) == kind)
    }

    @Test func budgetUpdatedRoundTrips() throws {
        let kind = StreamEvent.Kind.budgetUpdated(
            budget: ContextBudget(windowSize: 4096, currentUsage: 2000, softThreshold: 0.75)
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func budgetAdvisoryRoundTrips() throws {
        let kind = StreamEvent.Kind.budgetAdvisory(
            budget: ContextBudget(windowSize: 4096, currentUsage: 3500, softThreshold: 0.8)
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func toolApprovalRequestedRoundTrips() throws {
        let kind = StreamEvent.Kind.toolApprovalRequested(ToolApprovalRequest(
            toolCallId: "tc_1",
            toolName: "delete_file",
            arguments: #"{"path":"/tmp/test"}"#,
            toolDescription: "Deletes a file"
        ))
        #expect(try roundTrip(kind) == kind)
    }

    @Test func toolApprovalResolvedRoundTrips() throws {
        let kind = StreamEvent.Kind.toolApprovalResolved(
            toolCallId: "tc_1",
            decision: .deny(reason: "too risky")
        )
        #expect(try roundTrip(kind) == kind)
    }
}

struct StreamEventRecursiveCodableTests {
    private func requiredUUID(_ value: String) throws -> UUID {
        try #require(UUID(uuidString: value))
    }

    @Test func twoLevelNestingRoundTrips() throws {
        let innerID = try EventID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000001"))
        let innerSessionID = try SessionID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000002"))
        let innerRunID = try RunID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000003"))
        let innerParentEventID = try EventID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000004"))
        let innerTimestamp = Date(timeIntervalSince1970: 0.123)
        let innerEvent = StreamEvent(
            id: innerID,
            timestamp: innerTimestamp,
            sessionID: innerSessionID,
            runID: innerRunID,
            parentEventID: innerParentEventID,
            kind: .delta("leaf")
        )
        let outerKind = StreamEvent.Kind.subAgentEvent(
            toolCallId: "tc_outer",
            toolName: "agent_a",
            event: innerEvent
        )
        let outerEvent = StreamEvent(kind: outerKind)

        let data = try JSONEncoder().encode(outerEvent)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        guard case let .subAgentEvent(toolCallId, toolName, nestedEvent) = decoded.kind else {
            Issue.record("Expected subAgentEvent, got \(decoded.kind)")
            return
        }
        #expect(toolCallId == "tc_outer")
        #expect(toolName == "agent_a")
        #expect(nestedEvent.id == innerID)
        #expect(abs(nestedEvent.timestamp.timeIntervalSince1970 - innerTimestamp.timeIntervalSince1970) < 0.001)
        #expect(nestedEvent.sessionID == innerSessionID)
        #expect(nestedEvent.runID == innerRunID)
        #expect(nestedEvent.parentEventID == innerParentEventID)
        #expect(nestedEvent.kind == .delta("leaf"))
    }

    @Test func threeLevelNestingRoundTrips() throws {
        let level3ID = try EventID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000011"))
        let level3SessionID = try SessionID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000012"))
        let level3RunID = try RunID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000013"))
        let level3ParentEventID = try EventID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000014"))
        let level3Timestamp = Date(timeIntervalSince1970: 10.456)
        let level3 = StreamEvent(
            id: level3ID,
            timestamp: level3Timestamp,
            sessionID: level3SessionID,
            runID: level3RunID,
            parentEventID: level3ParentEventID,
            kind: .reasoningDelta("thinking")
        )
        let level2Kind = StreamEvent.Kind.subAgentEvent(
            toolCallId: "tc_l2",
            toolName: "agent_b",
            event: level3
        )
        let level2ID = try EventID(rawValue: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000021")))
        let level2Timestamp = Date(timeIntervalSince1970: 20.789)
        let level2 = StreamEvent(id: level2ID, timestamp: level2Timestamp, kind: level2Kind)
        let level1Kind = StreamEvent.Kind.subAgentEvent(
            toolCallId: "tc_l1",
            toolName: "agent_a",
            event: level2
        )
        let level1 = StreamEvent(kind: level1Kind)

        let data = try JSONEncoder().encode(level1)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        guard case let .subAgentEvent(_, _, mid) = decoded.kind else {
            Issue.record("Expected level 1 subAgentEvent")
            return
        }
        guard case let .subAgentEvent(_, _, leaf) = mid.kind else {
            Issue.record("Expected level 2 subAgentEvent")
            return
        }
        #expect(mid.id == level2ID)
        #expect(abs(mid.timestamp.timeIntervalSince1970 - level2Timestamp.timeIntervalSince1970) < 0.001)
        #expect(leaf.id == level3ID)
        #expect(abs(leaf.timestamp.timeIntervalSince1970 - level3Timestamp.timeIntervalSince1970) < 0.001)
        #expect(leaf.sessionID == level3SessionID)
        #expect(leaf.runID == level3RunID)
        #expect(leaf.parentEventID == level3ParentEventID)
        #expect(leaf.kind == .reasoningDelta("thinking"))
    }
}

struct StreamEventKindEqualityTests {
    @Test func subAgentEventEqualityIgnoresNestedEnvelope() {
        let innerA = StreamEvent(id: EventID(), timestamp: Date(timeIntervalSince1970: 1), kind: .delta("same"))
        let innerB = StreamEvent(id: EventID(), timestamp: Date(timeIntervalSince1970: 2), kind: .delta("same"))
        let kindA = StreamEvent.Kind.subAgentEvent(toolCallId: "tc", toolName: "agent", event: innerA)
        let kindB = StreamEvent.Kind.subAgentEvent(toolCallId: "tc", toolName: "agent", event: innerB)
        #expect(kindA == kindB)
    }

    @Test func subAgentEventInequalityWhenNestedKindDiffers() {
        let innerA = StreamEvent(kind: .delta("alpha"))
        let innerB = StreamEvent(kind: .delta("beta"))
        let kindA = StreamEvent.Kind.subAgentEvent(toolCallId: "tc", toolName: "agent", event: innerA)
        let kindB = StreamEvent.Kind.subAgentEvent(toolCallId: "tc", toolName: "agent", event: innerB)
        #expect(kindA != kindB)
    }
}

struct StreamEventEnvelopeCodableTests {
    @Test func allFieldsSurviveRoundTrip() throws {
        let id = EventID()
        let sessionID = SessionID()
        let runID = RunID()
        let parentEventID = EventID()
        let event = StreamEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_711_800_000),
            sessionID: sessionID,
            runID: runID,
            parentEventID: parentEventID,
            kind: .delta("test")
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.sessionID == sessionID)
        #expect(decoded.runID == runID)
        #expect(decoded.parentEventID == parentEventID)
        #expect(decoded.kind == .delta("test"))
    }

    @Test func timestampPreservesMillisecondPrecision() throws {
        let event = StreamEvent(
            timestamp: Date(timeIntervalSince1970: 1_711_800_000.123),
            kind: .delta("ts")
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(abs(decoded.timestamp.timeIntervalSince1970 - 1_711_800_000.123) < 0.001)
    }

    @Test func timestampEncodesAsStableISO8601String() throws {
        let event = StreamEvent(
            timestamp: Date(timeIntervalSince1970: 0.123),
            kind: .delta("ts")
        )

        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["timestamp"] as? String == "1970-01-01T00:00:00.123Z")
    }

    @Test func nilOptionalFieldsOmittedFromJSON() throws {
        let event = StreamEvent(kind: .delta("bare"))
        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["sessionID"] == nil)
        #expect(json["runID"] == nil)
        #expect(json["parentEventID"] == nil)
    }

    @Test func nonNilOptionalFieldsPreserved() throws {
        let sessionID = SessionID()
        let runID = RunID()
        let parentEventID = EventID()
        let event = StreamEvent(
            sessionID: sessionID,
            runID: runID,
            parentEventID: parentEventID,
            kind: .delta("ctx")
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded.sessionID == sessionID)
        #expect(decoded.runID == runID)
        #expect(decoded.parentEventID == parentEventID)
    }
}

struct StreamEventFinishedCodableTests {
    @Test func nonTrivialHistoryRoundTrips() throws {
        let history: [ChatMessage] = [
            .system("You are helpful."),
            .user("What is 2+2?"),
            .assistant(AssistantMessage(
                content: "Let me calculate.",
                toolCalls: [ToolCall(id: "tc_1", name: "calculator", arguments: #"{"expr":"2+2"}"#)]
            )),
            .tool(id: "tc_1", name: "calculator", content: "4"),
            .assistant(AssistantMessage(content: "The answer is 4.")),
        ]
        let kind = StreamEvent.Kind.finished(
            tokenUsage: TokenUsage(input: 150, output: 30, reasoning: 5, cacheRead: 10, cacheWrite: 20),
            content: "The answer is 4.",
            reason: .completed,
            history: history
        )
        let event = StreamEvent(kind: kind)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded.kind == kind)
    }

    @Test func nilContentAndReasonOmittedFromJSON() throws {
        let kind = StreamEvent.Kind.finished(
            tokenUsage: TokenUsage(input: 10, output: 5),
            content: nil,
            reason: nil,
            history: []
        )
        let event = StreamEvent(kind: kind)

        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kindJSON = try #require(json["kind"] as? [String: Any])

        #expect(kindJSON["content"] == nil)
        #expect(kindJSON["reason"] == nil)
        #expect(kindJSON["history"] is [Any])

        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)
        #expect(decoded.kind == kind)
    }
}

struct StreamEventAudioDataCodableTests {
    @Test func nonTrivialBinaryDataRoundTrips() throws {
        let bytes = Data(UInt8.min ... UInt8.max)
        let kind = StreamEvent.Kind.audioData(bytes)
        let event = StreamEvent(kind: kind)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        guard case let .audioData(decodedBytes) = decoded.kind else {
            Issue.record("Expected audioData, got \(decoded.kind)")
            return
        }
        #expect(decodedBytes == bytes)
    }

    @Test func emptyDataRoundTrips() throws {
        let kind = StreamEvent.Kind.audioData(Data())
        let event = StreamEvent(kind: kind)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded.kind == kind)
    }
}

struct StreamEventDiscriminatorTests {
    @Test func deltaDiscriminatorIsStable() throws {
        let event = StreamEvent(kind: .delta("Hello"))
        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kindJSON = try #require(json["kind"] as? [String: Any])
        #expect(kindJSON["type"] as? String == "delta")
    }

    @Test func unknownTypeDiscriminatorThrowsDecodingError() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "timestamp": "2026-03-30T14:22:07.123Z",
            "kind": {
                "type": "unknownFutureEvent",
                "data": "something"
            }
        }
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
        }
    }

    @Test func invalidTimestampThrowsDecodingError() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "timestamp": "not-a-date",
            "kind": {
                "type": "delta",
                "text": "hello"
            }
        }
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
        }
    }

    @Test func unknownTypeErrorMessageIncludesTypeName() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "timestamp": "2026-03-30T14:22:07.123Z",
            "kind": {
                "type": "teleport",
                "destination": "mars"
            }
        }
        """
        do {
            _ = try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
            Issue.record("Expected DecodingError")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("teleport"))
        } catch {
            Issue.record("Expected DecodingError.dataCorrupted, got \(error)")
        }
    }
}
