import Foundation

public enum TTSError: Error, Sendable, Equatable, LocalizedError {
    case emptyText
    case chunkFailed(index: Int, total: Int, TransportError)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "TTS input text is empty"
        case let .chunkFailed(index, total, error):
            "TTS chunk \(index + 1)/\(total) failed: \(error)"
        case let .invalidConfiguration(message):
            "TTS configuration error: \(message)"
        }
    }
}
