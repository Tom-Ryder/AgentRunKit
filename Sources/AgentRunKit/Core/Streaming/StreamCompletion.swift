import Foundation

/// Diagnostics for a successfully completed LLM stream call.
public struct StreamCompletionDiagnostics: Sendable, Equatable {
    public let elapsed: Duration
    public let eventsObserved: Int
    /// Whether the stream ended through the provider's own completion signal rather than completion inferred at EOF.
    public let terminalMarkerSeen: Bool

    public init(elapsed: Duration, eventsObserved: Int, terminalMarkerSeen: Bool) {
        self.elapsed = elapsed
        self.eventsObserved = eventsObserved
        self.terminalMarkerSeen = terminalMarkerSeen
    }
}

/// Terminal state for one underlying LLM stream call.
public enum StreamCompletion: Sendable, Equatable {
    case success(diagnostics: StreamCompletionDiagnostics)
    case failed(StreamFailure)
    case cancelled
}
