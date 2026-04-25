@testable import AgentRunKit
import Foundation
import Testing

struct FinishReasonCodableTests {
    private func roundTrip(_ value: FinishReason) throws -> FinishReason {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(FinishReason.self, from: data)
    }

    @Test func completedRoundTrips() throws {
        #expect(try roundTrip(.completed) == .completed)
    }

    @Test func errorRoundTrips() throws {
        #expect(try roundTrip(.error) == .error)
    }

    @Test func customRoundTrips() throws {
        #expect(try roundTrip(.custom("stopped")) == .custom("stopped"))
    }

    @Test func maxIterationsReachedRoundTrips() throws {
        #expect(try roundTrip(.maxIterationsReached(limit: 7)) == .maxIterationsReached(limit: 7))
    }

    @Test func tokenBudgetExceededRoundTrips() throws {
        #expect(try roundTrip(.tokenBudgetExceeded(budget: 100, used: 140)) == .tokenBudgetExceeded(
            budget: 100,
            used: 140
        ))
    }

    @Test func emptyCustomRoundTrips() throws {
        #expect(try roundTrip(.custom("")) == .custom(""))
    }

    @Test func customPreservesCase() throws {
        #expect(try roundTrip(.custom("STOPPED")) == .custom("STOPPED"))
    }

    @Test func customCompletedRoundTripsAsCustom() throws {
        #expect(try roundTrip(.custom("completed")) == .custom("completed"))
    }

    @Test func customErrorRoundTripsAsCustom() throws {
        #expect(try roundTrip(.custom("error")) == .custom("error"))
    }

    @Test func discriminatorIsStable() throws {
        let data = try JSONEncoder().encode(FinishReason.completed)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "completed")
    }

    @Test func customDiscriminatorIsStable() throws {
        let data = try JSONEncoder().encode(FinishReason.custom("stopped"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "custom")
        #expect(json["value"] as? String == "stopped")
    }

    @Test func maxIterationsReachedDiscriminatorIsStable() throws {
        let data = try JSONEncoder().encode(FinishReason.maxIterationsReached(limit: 9))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "maxIterationsReached")
        #expect(json["limit"] as? Int == 9)
    }

    @Test func tokenBudgetExceededDiscriminatorIsStable() throws {
        let data = try JSONEncoder().encode(FinishReason.tokenBudgetExceeded(budget: 10, used: 12))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "tokenBudgetExceeded")
        #expect(json["budget"] as? Int == 10)
        #expect(json["used"] as? Int == 12)
    }

    @Test func initMapsArbitraryStringToCustom() {
        #expect(FinishReason("paused") == .custom("paused"))
    }

    @Test func unknownTypeThrowsDecodingError() throws {
        let json = #"{"type":"mystery"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FinishReason.self, from: Data(json.utf8))
        }
    }
}

struct ContextBudgetCodableTests {
    private func roundTrip(_ value: ContextBudget) throws -> ContextBudget {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ContextBudget.self, from: data)
    }

    @Test func roundTripsWithoutSoftThreshold() throws {
        let budget = ContextBudget(windowSize: 4096, currentUsage: 1000)
        #expect(try roundTrip(budget) == budget)
    }

    @Test func roundTripsWithSoftThreshold() throws {
        let budget = ContextBudget(windowSize: 8192, currentUsage: 6000, softThreshold: 0.8)
        #expect(try roundTrip(budget) == budget)
    }

    @Test func rejectsInvalidWindowSize() throws {
        let json = #"{"windowSize": 0, "currentUsage": 0}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ContextBudget.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsNegativeCurrentUsage() throws {
        let json = #"{"windowSize": 100, "currentUsage": -1}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ContextBudget.self, from: Data(json.utf8))
        }
    }

    @Test func softThresholdOmittedWhenNil() throws {
        let budget = ContextBudget(windowSize: 100, currentUsage: 50)
        let data = try JSONEncoder().encode(budget)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["softThreshold"] == nil)
    }
}

struct ToolApprovalRequestCodableTests {
    private func roundTrip(_ value: ToolApprovalRequest) throws -> ToolApprovalRequest {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ToolApprovalRequest.self, from: data)
    }

    @Test func roundTripsAllFields() throws {
        let request = ToolApprovalRequest(
            toolCallId: "tc_1",
            toolName: "search",
            arguments: #"{"query":"swift"}"#,
            toolDescription: "Search the web"
        )
        #expect(try roundTrip(request) == request)
    }
}

struct ToolApprovalDecisionCodableTests {
    private func roundTrip(_ value: ToolApprovalDecision) throws -> ToolApprovalDecision {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ToolApprovalDecision.self, from: data)
    }

    @Test func approveRoundTrips() throws {
        #expect(try roundTrip(.approve) == .approve)
    }

    @Test func approveAlwaysRoundTrips() throws {
        #expect(try roundTrip(.approveAlways) == .approveAlways)
    }

    @Test func approveWithModifiedArgumentsRoundTrips() throws {
        let decision = ToolApprovalDecision.approveWithModifiedArguments(#"{"safe":true}"#)
        #expect(try roundTrip(decision) == decision)
    }

    @Test func denyWithReasonRoundTrips() throws {
        #expect(try roundTrip(.deny(reason: "too dangerous")) == .deny(reason: "too dangerous"))
    }

    @Test func denyWithNilReasonRoundTrips() throws {
        #expect(try roundTrip(.deny(reason: nil)) == .deny(reason: nil))
    }

    @Test func unknownTypeThrowsDecodingError() throws {
        let json = #"{"type":"unknown"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ToolApprovalDecision.self, from: Data(json.utf8))
        }
    }

    @Test func discriminatorIsStable() throws {
        let data = try JSONEncoder().encode(ToolApprovalDecision.approve)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "approve")
    }
}

struct EventIDCodableTests {
    @Test func roundTrips() throws {
        let id = EventID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(EventID.self, from: data)
        #expect(decoded == id)
    }

    @Test func encodesAsFlatUUIDString() throws {
        let id = EventID()
        let data = try JSONEncoder().encode(id)
        let string = try JSONDecoder().decode(String.self, from: data)
        #expect(string == id.rawValue.uuidString)
    }

    @Test func rejectsMalformedUUIDString() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventID.self, from: Data(#""not-a-uuid""#.utf8))
        }
    }
}

struct SessionIDCodableTests {
    @Test func roundTrips() throws {
        let id = SessionID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(SessionID.self, from: data)
        #expect(decoded == id)
    }

    @Test func encodesAsFlatUUIDString() throws {
        let id = SessionID()
        let data = try JSONEncoder().encode(id)
        let string = try JSONDecoder().decode(String.self, from: data)
        #expect(string == id.rawValue.uuidString)
    }

    @Test func rejectsMalformedUUIDString() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionID.self, from: Data(#""not-a-uuid""#.utf8))
        }
    }
}

struct RunIDCodableTests {
    @Test func roundTrips() throws {
        let id = RunID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(RunID.self, from: data)
        #expect(decoded == id)
    }

    @Test func encodesAsFlatUUIDString() throws {
        let id = RunID()
        let data = try JSONEncoder().encode(id)
        let string = try JSONDecoder().decode(String.self, from: data)
        #expect(string == id.rawValue.uuidString)
    }

    @Test func rejectsMalformedUUIDString() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RunID.self, from: Data(#""not-a-uuid""#.utf8))
        }
    }
}
