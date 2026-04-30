@testable import AgentRunKit
import Foundation
import Testing

struct OpenAIChatExtraFieldsCollisionTests {
    @Test
    func reservedToolChoiceKeyThrowsWithExactProviderMessage() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            extraFields: ["tool_choice": .string("required"), "model": .string("override")]
        )

        do {
            _ = try JSONEncoder().encode(request)
            Issue.record("Expected EncodingError")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(context.debugDescription == "Reserved extraFields keys for OpenAI Chat: model, tool_choice")
        } catch {
            Issue.record("Expected EncodingError.invalidValue, got \(error)")
        }
    }

    @Test
    func reservedMaxTokensKeyThrowsWithExactProviderMessage() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            extraFields: ["max_completion_tokens": .int(100)]
        )
        do {
            _ = try JSONEncoder().encode(request)
            Issue.record("Expected EncodingError")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(context.debugDescription == "Reserved extraFields keys for OpenAI Chat: max_completion_tokens")
        } catch {
            Issue.record("Expected EncodingError.invalidValue, got \(error)")
        }
    }

    @Test
    func nonReservedKey_passesThrough() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            extraFields: ["temperature": .double(0.5)]
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["temperature"] as? Double == 0.5)
    }
}
