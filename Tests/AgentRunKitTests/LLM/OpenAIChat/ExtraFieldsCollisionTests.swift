@testable import AgentRunKit
import Foundation
import Testing

struct OpenAIChatExtraFieldsCollisionTests {
    @Test
    func reservedToolChoiceKey_throws() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            extraFields: ["tool_choice": .string("required")]
        )
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(request)
        }
    }

    @Test
    func reservedMaxTokensKey_throws() throws {
        let client = OpenAIClient.openAI(apiKey: "k", model: "gpt-5.4")
        let request = try client.buildRequest(
            messages: [.user("Hi")],
            tools: [],
            extraFields: ["max_completion_tokens": .int(100)]
        )
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(request)
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
