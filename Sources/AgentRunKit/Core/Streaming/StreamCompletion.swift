import Foundation

/// Diagnostics for a successfully completed LLM stream call.
public struct StreamCompletionDiagnostics: Sendable, Equatable {
    public let elapsed: Duration
    public let eventsObserved: Int

    public init(elapsed: Duration, eventsObserved: Int) {
        self.elapsed = elapsed
        self.eventsObserved = eventsObserved
    }
}

/// Terminal state for one underlying LLM stream call.
public enum StreamCompletion: Sendable, Equatable {
    case success(diagnostics: StreamCompletionDiagnostics)
    case failed(StreamFailure)
    case cancelled
}
