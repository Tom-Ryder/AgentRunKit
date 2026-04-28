import Foundation

/// Errors from the TTS pipeline.
public enum TTSError: Error, Sendable, Equatable, LocalizedError {
    case emptyText
    case chunkFailed(index: Int, total: Int, sourceRange: Range<Int>, TransportError)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "TTS input text is empty"
        case let .chunkFailed(index, total, _, error):
            "TTS chunk \(index + 1)/\(total) failed: \(error)"
        case let .invalidConfiguration(message):
            "TTS configuration error: \(message)"
        }
    }
}
