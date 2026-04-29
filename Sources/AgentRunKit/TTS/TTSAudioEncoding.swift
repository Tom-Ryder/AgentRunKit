import Foundation

/// The audio encoding ``TTSClient`` requests from a provider for a segment.
public struct TTSAudioEncoding: Sendable, Equatable, Hashable, Codable {
    public let format: TTSAudioFormat
    public let mimeType: String
    public let fileExtension: String
    public let sampleRate: Int?
    public let channels: Int?
    public let bitsPerSample: Int?

    public init(
        format: TTSAudioFormat,
        mimeType: String,
        fileExtension: String,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        bitsPerSample: Int? = nil
    ) {
        self.format = format
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    public init(
        _ format: TTSAudioFormat,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        bitsPerSample: Int? = nil
    ) {
        self.init(
            format: format,
            mimeType: format.mimeType,
            fileExtension: format.fileExtension,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
    }
}
