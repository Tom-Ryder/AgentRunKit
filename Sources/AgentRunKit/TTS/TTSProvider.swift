import Foundation

/// A speech synthesis backend that converts text to audio.
public protocol TTSProvider: Sendable {
    var config: TTSProviderConfig { get }

    /// Returns the concrete audio encoding the provider will produce for a requested format.
    func resolvedEncoding(
        for format: TTSAudioFormat,
        options: TTSOptions
    ) -> TTSAudioEncoding

    func generate(
        text: String,
        voice: String,
        options: TTSOptions,
        context: TTSChunkContext
    ) async throws -> Data
}

public extension TTSProvider {
    func resolvedEncoding(
        for format: TTSAudioFormat,
        options _: TTSOptions
    ) -> TTSAudioEncoding {
        TTSAudioEncoding(format)
    }
}

/// Configuration for a TTSProvider's chunking and default settings.
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

/// Per-request options for speech generation.
public struct TTSOptions: Sendable, Equatable {
    public let speed: Double?
    public let responseFormat: TTSAudioFormat?

    public init(speed: Double? = nil, responseFormat: TTSAudioFormat? = nil) {
        self.speed = speed
        self.responseFormat = responseFormat
    }
}
