import Foundation

/// The chunk and requested encoding ``TTSClient`` delivers to a provider for one synthesis call.
public struct TTSChunkContext: Sendable, Equatable, Codable {
    public let chunk: TTSChunk
    public let encoding: TTSAudioEncoding

    public init(chunk: TTSChunk, encoding: TTSAudioEncoding) {
        self.chunk = chunk
        self.encoding = encoding
    }
}
