@testable import AgentRunKit
import Foundation
import Testing

private let sampleImage = Data(repeating: 0xAB, count: 4)
private let samplePDF = Data(repeating: 0xCD, count: 8)

struct AnthropicMultimodalTests {
    private func encodeRequest(_ request: AnthropicRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func imageEncodesAsBase64Source() throws {
        let client = try AnthropicClient(apiKey: "k", model: "claude-sonnet-4-6")
        let message = ChatMessage.userMultimodal([
            .text("Describe"),
            .image(data: sampleImage, mimeType: "image/png")
        ])
        let request = try client.buildRequest(messages: [message], tools: [])
        let json = try encodeRequest(request)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])

        #expect(content[0]["type"] as? String == "text")
        #expect(content[1]["type"] as? String == "image")
        let source = try #require(content[1]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == sampleImage.base64EncodedString())
    }

    @Test
    func pdfEncodesAsDocument() throws {
        let client = try AnthropicClient(apiKey: "k", model: "claude-sonnet-4-6")
        let message = ChatMessage.userMultimodal([.pdf(data: samplePDF)])
        let request = try client.buildRequest(messages: [message], tools: [])
        let json = try encodeRequest(request)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "document")
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "application/pdf")
        #expect(source["data"] as? String == samplePDF.base64EncodedString())
    }

    @Test
    func audioRejectsWithFeatureUnsupported() throws {
        let client = try AnthropicClient(apiKey: "k", model: "claude-sonnet-4-6")
        let message = ChatMessage.userMultimodal([.audio(data: sampleImage, format: .mp3)])
        #expect(throws: AgentError.self) {
            _ = try client.buildRequest(messages: [message], tools: [])
        }
    }
}

struct GeminiMultimodalTests {
    private func encodeRequest(_ request: GeminiRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func imageEncodesAsInlineData() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-2.5-flash")
        let message = ChatMessage.userMultimodal([
            .text("What's in this image?"),
            .image(data: sampleImage, mimeType: "image/jpeg")
        ])
        let request = try client.buildRequest(messages: [message], tools: [])
        let json = try encodeRequest(request)
        let contents = try #require(json["contents"] as? [[String: Any]])
        let parts = try #require(contents[0]["parts"] as? [[String: Any]])

        #expect(parts[0]["text"] as? String == "What's in this image?")
        let inline = try #require(parts[1]["inlineData"] as? [String: Any])
        #expect(inline["mimeType"] as? String == "image/jpeg")
        #expect(inline["data"] as? String == sampleImage.base64EncodedString())
    }

    @Test
    func pdfEncodesAsInlineDataWithPdfMime() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-2.5-flash")
        let message = ChatMessage.userMultimodal([.pdf(data: samplePDF)])
        let request = try client.buildRequest(messages: [message], tools: [])
        let json = try encodeRequest(request)
        let contents = try #require(json["contents"] as? [[String: Any]])
        let parts = try #require(contents[0]["parts"] as? [[String: Any]])
        let inline = try #require(parts[0]["inlineData"] as? [String: Any])
        #expect(inline["mimeType"] as? String == "application/pdf")
        #expect(inline["data"] as? String == samplePDF.base64EncodedString())
    }

    @Test
    func audioEncodesAsInlineData() throws {
        let client = GeminiClient(apiKey: "k", model: "gemini-2.5-flash")
        let audio = Data(repeating: 0x01, count: 4)
        let message = ChatMessage.userMultimodal([.audio(data: audio, format: .wav)])
        let request = try client.buildRequest(messages: [message], tools: [])
        let json = try encodeRequest(request)
        let contents = try #require(json["contents"] as? [[String: Any]])
        let parts = try #require(contents[0]["parts"] as? [[String: Any]])
        let inline = try #require(parts[0]["inlineData"] as? [String: Any])
        #expect(inline["mimeType"] as? String == "audio/wav")
        #expect(inline["data"] as? String == audio.base64EncodedString())
    }
}
