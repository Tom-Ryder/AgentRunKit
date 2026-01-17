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
        #expect(msg.reasoning == nil)
    }

    @Test
    func withToolCalls() {
        let toolA = ToolCall(id: "1", name: "tool_a", arguments: "{\"x\":1}")
        let toolB = ToolCall(id: "2", name: "tool_b", arguments: "{\"y\":2}")
        let msg = AssistantMessage(content: "response", toolCalls: [toolA, toolB])
        #expect(msg.toolCalls == [toolA, toolB])
        #expect(msg.content == "response")
    }

    @Test
    func withReasoning() {
        let reasoning = ReasoningContent(content: "Thinking...", signature: "sig123")
        let msg = AssistantMessage(content: "Answer", reasoning: reasoning)
        #expect(msg.content == "Answer")
        #expect(msg.reasoning?.content == "Thinking...")
        #expect(msg.reasoning?.signature == "sig123")
    }
}

@Suite
struct ReasoningContentTests {
    @Test
    func initWithContentOnly() {
        let reasoning = ReasoningContent(content: "Thinking about the problem...")
        #expect(reasoning.content == "Thinking about the problem...")
        #expect(reasoning.signature == nil)
    }

    @Test
    func initWithSignature() {
        let reasoning = ReasoningContent(content: "Deep thoughts", signature: "sig123")
        #expect(reasoning.content == "Deep thoughts")
        #expect(reasoning.signature == "sig123")
    }

    @Test
    func codableRoundTrip() throws {
        let original = ReasoningContent(content: "Reasoning text", signature: "abc")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReasoningContent.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func codableRoundTripWithoutSignature() throws {
        let original = ReasoningContent(content: "Just content")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReasoningContent.self, from: data)
        #expect(decoded == original)
        #expect(decoded.signature == nil)
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

    @Test
    func assistantMessageWithReasoningRoundTrip() throws {
        let original = AssistantMessage(
            content: "Response",
            toolCalls: [],
            tokenUsage: TokenUsage(input: 10, output: 5),
            reasoning: ReasoningContent(content: "Thought process", signature: "sig")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AssistantMessage.self, from: data)
        #expect(decoded == original)
        #expect(decoded.reasoning?.content == "Thought process")
        #expect(decoded.reasoning?.signature == "sig")
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
    func userAudioRoundTrip() throws {
        let audioData = Data("audio".utf8)
        let original = ChatMessage.user(text: "Transcribe", audioData: audioData, format: .wav)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded == original)
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

@Suite
struct ContentPartTests {
    @Test
    func audioEncodesAsInputAudio() throws {
        let audioData = Data("audio".utf8)
        let part = ContentPart.audio(data: audioData, format: .wav)
        let data = try JSONEncoder().encode(part)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["type"] as? String == "input_audio")
        let inputAudio = json?["input_audio"] as? [String: Any]
        #expect(inputAudio?["format"] as? String == "wav")
        #expect(inputAudio?["data"] as? String == audioData.base64EncodedString())
    }

    @Test
    func audioRoundTrip() throws {
        let audioData = Data([0x01, 0x02, 0x03])
        let original = ContentPart.audio(data: audioData, format: .mp3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentPart.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func audioDecodeFailsWithoutData() throws {
        let json: [String: Any] = [
            "type": "input_audio",
            "input_audio": ["format": "wav"]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        do {
            _ = try JSONDecoder().decode(ContentPart.self, from: data)
            Issue.record("Expected decoding failure")
        } catch let DecodingError.keyNotFound(key, _) {
            #expect(key.stringValue == "data")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func audioDecodeFailsWithInvalidBase64() throws {
        let json: [String: Any] = [
            "type": "input_audio",
            "input_audio": [
                "format": "wav",
                "data": "not-base64"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        do {
            _ = try JSONDecoder().decode(ContentPart.self, from: data)
            Issue.record("Expected decoding failure")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription == "input_audio.data is not valid base64")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func audioDecodeFailsWithUnknownFormat() throws {
        let audioData = Data("audio".utf8)
        let json: [String: Any] = [
            "type": "input_audio",
            "input_audio": [
                "format": "aac",
                "data": audioData.base64EncodedString()
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        do {
            _ = try JSONDecoder().decode(ContentPart.self, from: data)
            Issue.record("Expected decoding failure")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("Unknown audio format"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite
struct AudioFormatTests {
    @Test
    func audioInputFormatMappings() {
        #expect(AudioInputFormat.wav.mimeType == "audio/wav")
        #expect(AudioInputFormat.mp3.mimeType == "audio/mpeg")
        #expect(AudioInputFormat.webm.fileExtension == "webm")
    }

    @Test
    func transcriptionAudioFormatMappings() {
        #expect(TranscriptionAudioFormat.mp3.mimeType == "audio/mpeg")
        #expect(TranscriptionAudioFormat.m4a.mimeType == "audio/mp4")
        #expect(TranscriptionAudioFormat.wav.fileExtension == "wav")
    }
}

@Suite
struct ChatMessageTruncationTests {
    @Test
    func truncationPreservesRecentMessages() {
        let messages: [ChatMessage] = [
            .user("1"),
            .assistant(AssistantMessage(content: "2")),
            .user("3"),
            .assistant(AssistantMessage(content: "4")),
            .user("5")
        ]
        let truncated = messages.truncated(to: 3)

        #expect(truncated.count == 3)
        guard case let .user(first) = truncated[0] else {
            Issue.record("Expected user message at index 0")
            return
        }
        #expect(first == "3")
        guard case let .assistant(second) = truncated[1] else {
            Issue.record("Expected assistant message at index 1")
            return
        }
        #expect(second.content == "4")
        guard case let .user(last) = truncated[2] else {
            Issue.record("Expected user message at index 2")
            return
        }
        #expect(last == "5")
    }

    @Test
    func truncationPreservesSystemPrompt() {
        let messages: [ChatMessage] = [
            .system("System prompt"),
            .user("1"),
            .assistant(AssistantMessage(content: "2")),
            .user("3")
        ]
        let truncated = messages.truncated(to: 2, preservingSystemPrompt: true)

        #expect(truncated.count == 3)
        guard case let .system(prompt) = truncated[0] else {
            Issue.record("Expected system message first")
            return
        }
        #expect(prompt == "System prompt")
        guard case .assistant = truncated[1] else {
            Issue.record("Expected assistant message")
            return
        }
        guard case let .user(msg) = truncated[2] else {
            Issue.record("Expected user message")
            return
        }
        #expect(msg == "3")
    }

    @Test
    func truncationWithoutPreservingSystem() {
        let messages: [ChatMessage] = [
            .system("System"),
            .user("1"),
            .assistant(AssistantMessage(content: "2"))
        ]
        let truncated = messages.truncated(to: 1, preservingSystemPrompt: false)

        #expect(truncated.count == 1)
        guard case .assistant = truncated[0] else {
            Issue.record("Expected assistant message")
            return
        }
    }

    @Test
    func noTruncationWhenUnderLimit() {
        let messages: [ChatMessage] = [
            .user("1"),
            .assistant(AssistantMessage(content: "2"))
        ]
        let truncated = messages.truncated(to: 5)

        #expect(truncated.count == 2)
    }

    @Test
    func emptyArrayReturnsEmpty() {
        let messages: [ChatMessage] = []
        let truncated = messages.truncated(to: 5)
        #expect(truncated.isEmpty)
    }

    @Test
    func singleMessageUnderLimitUnchanged() {
        let messages: [ChatMessage] = [.user("Only message")]
        let truncated = messages.truncated(to: 5)

        #expect(truncated.count == 1)
        guard case let .user(content) = truncated[0] else {
            Issue.record("Expected user message")
            return
        }
        #expect(content == "Only message")
    }

    @Test
    func exactlyAtLimitUnchanged() {
        let messages: [ChatMessage] = [
            .user("1"),
            .assistant(AssistantMessage(content: "2")),
            .user("3")
        ]
        let truncated = messages.truncated(to: 3)

        #expect(truncated.count == 3)
        guard case let .user(first) = truncated[0] else {
            Issue.record("Expected user message at index 0")
            return
        }
        #expect(first == "1")
    }

    @Test
    func systemPromptDoesNotCountTowardLimit() {
        let messages: [ChatMessage] = [
            .system("System prompt"),
            .user("1"),
            .assistant(AssistantMessage(content: "2")),
            .user("3")
        ]
        let truncated = messages.truncated(to: 2, preservingSystemPrompt: true)

        #expect(truncated.count == 3)
        guard case .system = truncated[0] else {
            Issue.record("Expected system message first")
            return
        }
        guard case .assistant = truncated[1] else {
            Issue.record("Expected assistant message second")
            return
        }
        guard case let .user(msg) = truncated[2] else {
            Issue.record("Expected user message third")
            return
        }
        #expect(msg == "3")
    }

    @Test
    func truncationWithZeroLimitReturnsOnlySystemPrompt() {
        let messages: [ChatMessage] = [
            .system("System prompt"),
            .user("1"),
            .assistant(AssistantMessage(content: "2"))
        ]
        let truncated = messages.truncated(to: 0, preservingSystemPrompt: true)

        #expect(truncated.count == 1)
        guard case let .system(prompt) = truncated[0] else {
            Issue.record("Expected system message only")
            return
        }
        #expect(prompt == "System prompt")
    }

    @Test
    func truncationWithoutSystemPromptAndZeroLimitReturnsEmpty() {
        let messages: [ChatMessage] = [
            .user("1"),
            .assistant(AssistantMessage(content: "2"))
        ]
        let truncated = messages.truncated(to: 0, preservingSystemPrompt: false)
        #expect(truncated.isEmpty)
    }

    @Test
    func truncationPreservesToolCallResultPairs() {
        let toolCall = ToolCall(id: "call_1", name: "search", arguments: "{}")
        let messages: [ChatMessage] = [
            .user("Old message"),
            .assistant(AssistantMessage(content: "Using tool", toolCalls: [toolCall])),
            .tool(id: "call_1", name: "search", content: "result"),
            .user("New message")
        ]
        let truncated = messages.truncated(to: 2)

        #expect(truncated.count == 3)
        guard case let .assistant(assistant) = truncated[0] else {
            Issue.record("Expected assistant with tool call preserved")
            return
        }
        #expect(assistant.toolCalls.first?.id == "call_1")
        guard case let .tool(id, _, _) = truncated[1] else {
            Issue.record("Expected tool result preserved")
            return
        }
        #expect(id == "call_1")
        guard case .user = truncated[2] else {
            Issue.record("Expected user message last")
            return
        }
    }

    @Test
    func truncationWithMultipleToolCallsKeepsPairs() {
        let call1 = ToolCall(id: "call_1", name: "tool_a", arguments: "{}")
        let call2 = ToolCall(id: "call_2", name: "tool_b", arguments: "{}")
        let messages: [ChatMessage] = [
            .user("Old"),
            .assistant(AssistantMessage(content: "response 1")),
            .user("Newer"),
            .assistant(AssistantMessage(content: "Using tools", toolCalls: [call1, call2])),
            .tool(id: "call_1", name: "tool_a", content: "result a"),
            .tool(id: "call_2", name: "tool_b", content: "result b"),
            .user("Newest")
        ]
        let truncated = messages.truncated(to: 4)

        #expect(truncated.count == 4)
        guard case let .assistant(assistant) = truncated[0] else {
            Issue.record("Expected assistant with tool calls")
            return
        }
        #expect(assistant.toolCalls.count == 2)
        guard case let .tool(id1, _, _) = truncated[1] else {
            Issue.record("Expected first tool result")
            return
        }
        #expect(id1 == "call_1")
        guard case let .tool(id2, _, _) = truncated[2] else {
            Issue.record("Expected second tool result")
            return
        }
        #expect(id2 == "call_2")
    }

    @Test
    func truncationWithCompletedToolCallAllowsCut() {
        let call1 = ToolCall(id: "call_1", name: "tool_a", arguments: "{}")
        let messages: [ChatMessage] = [
            .user("Old"),
            .assistant(AssistantMessage(content: "Using tool", toolCalls: [call1])),
            .tool(id: "call_1", name: "tool_a", content: "result"),
            .user("Middle"),
            .assistant(AssistantMessage(content: "response")),
            .user("Newest")
        ]
        let truncated = messages.truncated(to: 3)

        #expect(truncated.count == 3)
        guard case let .user(first) = truncated[0] else {
            Issue.record("Expected user message first")
            return
        }
        #expect(first == "Middle")
    }

    @Test
    func truncationDropsCompletePairsWhenPossible() {
        let call1 = ToolCall(id: "call_1", name: "tool_a", arguments: "{}")
        let messages: [ChatMessage] = [
            .assistant(AssistantMessage(content: "Using tool", toolCalls: [call1])),
            .tool(id: "call_1", name: "tool_a", content: "result"),
            .user("New")
        ]
        let truncated = messages.truncated(to: 1)

        #expect(truncated.count == 1)
        guard case let .user(content) = truncated[0] else {
            Issue.record("Expected user message")
            return
        }
        #expect(content == "New")
    }

    @Test
    func truncationNeverOrphansToolResult() {
        let call1 = ToolCall(id: "call_1", name: "tool_a", arguments: "{}")
        let messages: [ChatMessage] = [
            .user("Start"),
            .assistant(AssistantMessage(content: "Using tool", toolCalls: [call1])),
            .tool(id: "call_1", name: "tool_a", content: "result")
        ]
        let truncated = messages.truncated(to: 2)

        #expect(truncated.count == 2)
        guard case .assistant = truncated[0] else {
            Issue.record("Expected assistant preserved to avoid orphan")
            return
        }
        guard case .tool = truncated[1] else {
            Issue.record("Expected tool result preserved")
            return
        }
    }
}
