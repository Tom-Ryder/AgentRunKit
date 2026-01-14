import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct TokenUsageTests {
    @Test
    func total() {
        let usage = TokenUsage(input: 100, output: 50, reasoning: 25)
        #expect(usage.total == 175)
    }

    @Test
    func addition() {
        let lhs = TokenUsage(input: 100, output: 50, reasoning: 10)
        let rhs = TokenUsage(input: 200, output: 75, reasoning: 15)
        let sum = lhs + rhs
        #expect(sum.input == 300)
        #expect(sum.output == 125)
        #expect(sum.reasoning == 25)
        #expect(sum.total == 450)
    }

    @Test
    func defaultsToZero() {
        let usage = TokenUsage()
        #expect(usage.input == 0)
        #expect(usage.output == 0)
        #expect(usage.reasoning == 0)
        #expect(usage.total == 0)
    }

    @Test
    func additionSaturatesOnOverflow() {
        let nearMax = TokenUsage(input: Int.max - 10, output: Int.max - 10, reasoning: Int.max - 10)
        let small = TokenUsage(input: 100, output: 100, reasoning: 100)
        let result = nearMax + small
        #expect(result.input == Int.max)
        #expect(result.output == Int.max)
        #expect(result.reasoning == Int.max)
    }
}

@Suite
struct AssistantMessageTests {
    @Test
    func defaultValues() {
        let msg = AssistantMessage(content: "Hello")
        #expect(msg.content == "Hello")
        #expect(msg.toolCalls.isEmpty)
        #expect(msg.tokenUsage == nil)
    }

    @Test
    func withToolCalls() {
        let toolA = ToolCall(id: "1", name: "tool_a", arguments: "{\"x\":1}")
        let toolB = ToolCall(id: "2", name: "tool_b", arguments: "{\"y\":2}")
        let msg = AssistantMessage(content: "response", toolCalls: [toolA, toolB])
        #expect(msg.toolCalls == [toolA, toolB])
        #expect(msg.content == "response")
    }
}

@Suite
struct CodableRoundTripTests {
    @Test
    func tokenUsageRoundTrip() throws {
        let original = TokenUsage(input: 100, output: 50, reasoning: 25)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func toolCallRoundTrip() throws {
        let original = ToolCall(id: "123", name: "test", arguments: "{\"key\": \"value\"}")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func assistantMessageRoundTrip() throws {
        let original = AssistantMessage(
            content: "Hello",
            toolCalls: [ToolCall(id: "1", name: "test", arguments: "{}")],
            tokenUsage: TokenUsage(input: 10, output: 5)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AssistantMessage.self, from: data)
        #expect(decoded == original)
    }
}

@Suite
struct ChatMessageTests {
    @Test
    func systemMessageRoundTrip() throws {
        let original = ChatMessage.system("You are helpful")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded == original)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["role"] as? String == "system")
        #expect(json?["content"] as? String == "You are helpful")
    }

    @Test
    func userMessageRoundTrip() throws {
        let original = ChatMessage.user("Hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded == original)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["role"] as? String == "user")
    }

    @Test
    func assistantMessageRoundTrip() throws {
        let msg = AssistantMessage(content: "Hi", toolCalls: [], tokenUsage: TokenUsage(input: 10, output: 5))
        let original = ChatMessage.assistant(msg)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded == original)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["role"] as? String == "assistant")
    }

    @Test
    func toolMessageRoundTrip() throws {
        let original = ChatMessage.tool(id: "call_123", name: "get_weather", content: "{\"temp\": 72}")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded == original)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["role"] as? String == "tool")
        #expect(json?["id"] as? String == "call_123")
        #expect(json?["name"] as? String == "get_weather")
    }
}
