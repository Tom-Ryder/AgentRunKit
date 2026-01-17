import Foundation

public enum StreamDelta: Sendable, Equatable {
    case content(String)
    case reasoning(String)
    case toolCallStart(index: Int, id: String, name: String)
    case toolCallDelta(index: Int, arguments: String)
    case finished(usage: TokenUsage?)
}
