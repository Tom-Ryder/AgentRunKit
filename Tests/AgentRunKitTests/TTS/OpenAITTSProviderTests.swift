@testable import AgentRunKit
import Foundation
import Testing

private func makeContext(text: String = "Hi", format: TTSAudioFormat = .mp3) -> TTSChunkContext {
    TTSChunkContext(
        chunk: TTSChunk(index: 0, total: 1, text: text, sourceRange: 0 ..< text.utf8.count),
        encoding: TTSAudioEncoding(format)
    )
}

struct OpenAITTSProviderTests {
    private let provider = OpenAITTSProvider(
        apiKey: "test-key",
        model: "tts-1",
        baseURL: URL(validStaticString: "https://api.openai.com/v1")
    )

    @Test
    func requestBodyEncodesAllFields() throws {
        let options = TTSOptions(speed: 1.5)
        let request = try provider.buildURLRequest(
            text: "Hello world",
            voice: "nova",
            options: options,
            encoding: TTSAudioEncoding(.opus)
        )
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let parsed = try #require(json)

        #expect(parsed["model"] as? String == "tts-1")
        #expect(parsed["input"] as? String == "Hello world")
        #expect(parsed["voice"] as? String == "nova")
        #expect(parsed["response_format"] as? String == "opus")
        #expect(parsed["speed"] as? Double == 1.5)
    }

    @Test
    func requestBodyUsesEncodingFormatNotOptionsResponseFormat() throws {
        let options = TTSOptions(responseFormat: .opus)
        let request = try provider.buildURLRequest(
            text: "Hi",
            voice: "alloy",
            options: options,
            encoding: TTSAudioEncoding(.flac)
        )
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let parsed = try #require(json)
        #expect(parsed["response_format"] as? String == "flac")
    }

    @Test
    func authorizationHeaderIsSet() throws {
        let request = try provider.buildURLRequest(
            text: "Hi",
            voice: "alloy",
            options: TTSOptions(),
            encoding: TTSAudioEncoding(.mp3)
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test
    func contentTypeIsJSON() throws {
        let request = try provider.buildURLRequest(
            text: "Hi",
            voice: "alloy",
            options: TTSOptions(),
            encoding: TTSAudioEncoding(.mp3)
        )
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func requestURLIsCorrect() throws {
        let request = try provider.buildURLRequest(
            text: "Hi",
            voice: "alloy",
            options: TTSOptions(),
            encoding: TTSAudioEncoding(.mp3)
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
    }

    @Test
    func requestMethodIsPOST() throws {
        let request = try provider.buildURLRequest(
            text: "Hi",
            voice: "alloy",
            options: TTSOptions(),
            encoding: TTSAudioEncoding(.mp3)
        )
        #expect(request.httpMethod == "POST")
    }

    @Test
    func speedOutOfRangeThrowsInvalidConfiguration() async {
        await #expect(throws: TTSError.invalidConfiguration(
            "OpenAI TTS speed must be between 0.25 and 4.0, got 0.1"
        )) {
            try await provider.generate(
                text: "Hi",
                voice: "alloy",
                options: TTSOptions(speed: 0.1),
                context: makeContext()
            )
        }
    }

    @Test
    func speedAboveRangeThrowsInvalidConfiguration() async {
        await #expect(throws: TTSError.invalidConfiguration(
            "OpenAI TTS speed must be between 0.25 and 4.0, got 5.0"
        )) {
            try await provider.generate(
                text: "Hi",
                voice: "alloy",
                options: TTSOptions(speed: 5.0),
                context: makeContext()
            )
        }
    }

    @Test
    func speedNilOmitsSpeedField() throws {
        let request = try provider.buildURLRequest(
            text: "Hi",
            voice: "alloy",
            options: TTSOptions(),
            encoding: TTSAudioEncoding(.mp3)
        )
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let parsed = try #require(json)

        #expect(parsed["speed"] == nil)
    }

    @Test
    func speedWithinRangeIncludesSpeedField() throws {
        let options = TTSOptions(speed: 2.0)
        let request = try provider.buildURLRequest(
            text: "Hi",
            voice: "alloy",
            options: options,
            encoding: TTSAudioEncoding(.mp3)
        )
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let parsed = try #require(json)

        #expect(parsed["speed"] as? Double == 2.0)
    }

    @Test
    func defaultConfigValues() {
        let defaultProvider = OpenAITTSProvider(apiKey: "key")
        #expect(defaultProvider.config.maxChunkCharacters == 4096)
        #expect(defaultProvider.config.defaultVoice == "alloy")
        #expect(defaultProvider.config.defaultFormat == .mp3)
        #expect(defaultProvider.model == "tts-1")
    }

    @Test
    func networkErrorUnwrappedFromAgentError() async throws {
        let unreachableProvider = try OpenAITTSProvider(
            apiKey: "key",
            baseURL: #require(URL(string: "http://localhost:1")),
            session: .shared,
            retryPolicy: RetryPolicy(maxAttempts: 1)
        )
        do {
            _ = try await unreachableProvider.generate(
                text: "Hi",
                voice: "alloy",
                options: TTSOptions(),
                context: makeContext()
            )
            Issue.record("Expected TransportError")
        } catch let error as TransportError {
            if case .networkError = error {} else {
                Issue.record("Expected .networkError, got \(error)")
            }
        } catch {
            Issue.record("Expected TransportError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func cancellationPropagatesThroughGenerate() async throws {
        let slowProvider = try OpenAITTSProvider(
            apiKey: "key",
            baseURL: #require(URL(string: "http://10.255.255.1")),
            session: .shared,
            retryPolicy: RetryPolicy(maxAttempts: 1)
        )
        let task = Task {
            try await slowProvider.generate(
                text: "Hi",
                voice: "alloy",
                options: TTSOptions(),
                context: makeContext()
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func resolvedEncodingForPCMReturnsDocumentedFormatValues() {
        let encoding = provider.resolvedEncoding(for: .pcm, options: TTSOptions())
        #expect(encoding.format == .pcm)
        #expect(encoding.sampleRate == 24000)
        #expect(encoding.bitsPerSample == 16)
        #expect(encoding.mimeType == TTSAudioFormat.pcm.mimeType)
        #expect(encoding.fileExtension == TTSAudioFormat.pcm.fileExtension)
    }

    @Test
    func resolvedEncodingForPCMLeavesChannelsNilUntilSpeechEndpointDocumentsIt() {
        let encoding = provider.resolvedEncoding(for: .pcm, options: TTSOptions())
        #expect(encoding.channels == nil)
    }

    @Test
    func resolvedEncodingForNonPCMFormatsLeavesPCMFieldsNil() {
        for format in TTSAudioFormat.allCases where format != .pcm {
            let encoding = provider.resolvedEncoding(for: format, options: TTSOptions())
            #expect(encoding.format == format)
            #expect(encoding.sampleRate == nil)
            #expect(encoding.channels == nil)
            #expect(encoding.bitsPerSample == nil)
        }
    }

    @Test
    func resolvedEncodingForPCMIgnoresOptionsSpeedAndResponseFormat() {
        let opts = TTSOptions(speed: 2.5, responseFormat: .mp3)
        let encoding = provider.resolvedEncoding(for: .pcm, options: opts)
        #expect(encoding.format == .pcm)
        #expect(encoding.sampleRate == 24000)
        #expect(encoding.channels == nil)
        #expect(encoding.bitsPerSample == 16)
    }

    @Test
    func speedAtBoundariesIsAccepted() throws {
        let lowRequest = try provider.buildURLRequest(
            text: "Hi",
            voice: "alloy",
            options: TTSOptions(speed: 0.25),
            encoding: TTSAudioEncoding(.mp3)
        )
        let lowBody = try #require(lowRequest.httpBody)
        let lowJSON = try #require(JSONSerialization.jsonObject(with: lowBody) as? [String: Any])
        #expect(lowJSON["speed"] as? Double == 0.25)

        let highRequest = try provider.buildURLRequest(
            text: "Hi",
            voice: "alloy",
            options: TTSOptions(speed: 4.0),
            encoding: TTSAudioEncoding(.mp3)
        )
        let highBody = try #require(highRequest.httpBody)
        let highJSON = try #require(JSONSerialization.jsonObject(with: highBody) as? [String: Any])
        #expect(highJSON["speed"] as? Double == 4.0)
    }
}
