import Foundation

public struct OpenAITTSProvider: TTSProvider, Sendable {
    public let config: TTSProviderConfig
    let apiKey: String
    let baseURL: URL
    let model: String
    let session: URLSession
    let retryPolicy: RetryPolicy

    public init(
        apiKey: String,
        model: String = "tts-1",
        baseURL: URL = OpenAIClient.openAIBaseURL,
        maxChunkCharacters: Int = 4096,
        defaultVoice: String = "alloy",
        defaultFormat: TTSAudioFormat = .mp3,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.retryPolicy = retryPolicy
        config = TTSProviderConfig(
            maxChunkCharacters: maxChunkCharacters,
            defaultVoice: defaultVoice,
            defaultFormat: defaultFormat
        )
    }

    public func generate(text: String, voice: String, options: TTSOptions) async throws -> Data {
        if let speed = options.speed {
            guard (0.25 ... 4.0).contains(speed) else {
                throw TTSError.invalidConfiguration(
                    "OpenAI TTS speed must be between 0.25 and 4.0, got \(speed)"
                )
            }
        }

        let urlRequest = try buildURLRequest(text: text, voice: voice, options: options)

        do {
            let (data, _) = try await HTTPRetry.performData(
                urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
            )
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let AgentError.llmError(transportError) {
            throw transportError
        } catch {
            throw TransportError.other(String(describing: error))
        }
    }

    func buildURLRequest(text: String, voice: String, options: TTSOptions) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("audio/speech")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = TTSRequestBody(
            model: model,
            input: text,
            voice: voice,
            responseFormat: (options.responseFormat ?? config.defaultFormat).rawValue,
            speed: options.speed
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }
}

private struct TTSRequestBody: Encodable {
    let model: String
    let input: String
    let voice: String
    let responseFormat: String
    let speed: Double?

    enum CodingKeys: String, CodingKey {
        case model, input, voice
        case responseFormat = "response_format"
        case speed
    }
}
