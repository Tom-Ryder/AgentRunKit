import Foundation

public enum TTSAudioFormat: String, Sendable, Codable, CaseIterable {
    case mp3, opus, aac, flac, wav, pcm
}

public protocol TTSProvider: Sendable {
    var config: TTSProviderConfig { get }
    func generate(text: String, voice: String, options: TTSOptions) async throws -> Data
}

public struct TTSProviderConfig: Sendable, Equatable {
    public let maxChunkCharacters: Int
    public let defaultVoice: String
    public let defaultFormat: TTSAudioFormat

    public init(maxChunkCharacters: Int, defaultVoice: String, defaultFormat: TTSAudioFormat) {
        precondition(maxChunkCharacters >= 1, "maxChunkCharacters must be at least 1")
        precondition(!defaultVoice.isEmpty, "defaultVoice must not be empty")
        self.maxChunkCharacters = maxChunkCharacters
        self.defaultVoice = defaultVoice
        self.defaultFormat = defaultFormat
    }
}

public struct TTSOptions: Sendable, Equatable {
    public let speed: Double?
    public let responseFormat: TTSAudioFormat?

    public init(speed: Double? = nil, responseFormat: TTSAudioFormat? = nil) {
        self.speed = speed
        self.responseFormat = responseFormat
    }
}
