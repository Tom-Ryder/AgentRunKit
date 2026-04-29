import Foundation

/// An audio container or codec the orchestrator can request from a ``TTSProvider``.
public enum TTSAudioFormat: String, Sendable, Codable, CaseIterable {
    case mp3, opus, aac, flac, wav, pcm

    public var mimeType: String {
        switch self {
        case .mp3:
            "audio/mpeg"
        case .opus:
            "audio/opus"
        case .aac:
            "audio/aac"
        case .flac:
            "audio/flac"
        case .wav:
            "audio/wav"
        case .pcm:
            "audio/L16"
        }
    }

    public var fileExtension: String {
        rawValue
    }
}
