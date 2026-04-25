import Foundation

/// Incremental deltas from an LLM streaming response.
public enum StreamDelta: Sendable, Equatable {
    case content(String)
    case reasoning(String)
    case reasoningDetails([JSONValue])
    case toolCallStart(index: Int, id: String, name: String, kind: ToolCallKind)
    case toolCallDelta(index: Int, arguments: String)
    case audioData(Data)
    case audioTranscript(String)
    case audioStarted(id: String, expiresAt: Int)
    case finished(usage: TokenUsage?)
}
