@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesReasoningConfigTests {
    private func encode(_ config: ResponsesReasoningConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(config)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("Encoded ResponsesReasoningConfig is not a JSON object")
        }
        return dict
    }

    @Test
    func excludedReasoning_omitsSummaryKey() throws {
        let config = ResponsesReasoningConfig(ReasoningConfig(effort: .high, exclude: true))
        let json = try encode(config)
        #expect(json["effort"] as? String == "high")
        #expect(json["summary"] == nil)
    }

    @Test
    func includedReasoning_defaultsToAuto() throws {
        let config = ResponsesReasoningConfig(ReasoningConfig(effort: .high))
        let json = try encode(config)
        #expect(json["summary"] as? String == "auto")
    }

    @Test
    func allEffortValues_encodeAsSummaryAutoWhenIncluded() throws {
        for effort in [ReasoningConfig.Effort.minimal, .low, .medium, .high, .xhigh] {
            let config = ResponsesReasoningConfig(ReasoningConfig(effort: effort))
            let json = try encode(config)
            #expect(json["summary"] as? String == "auto", "effort \(effort) must default summary to auto")
            #expect(json["effort"] as? String == effort.rawValue)
        }
    }
}
