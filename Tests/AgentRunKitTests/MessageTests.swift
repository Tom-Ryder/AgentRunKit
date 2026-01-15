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
