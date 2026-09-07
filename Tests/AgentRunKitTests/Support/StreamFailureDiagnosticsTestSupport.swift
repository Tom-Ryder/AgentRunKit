@testable import AgentRunKit
import Foundation
import Testing

extension StreamFailureDiagnostics {
    static let empty = StreamFailureDiagnostics(
        provider: .custom("test"),
        elapsed: .zero,
        eventsObserved: 0,
        finishSignalSeen: false,
        lastEvent: nil
    )
}

func collectStreamResult(
    _ stream: AsyncThrowingStream<StreamDelta, Error>
) async -> (deltas: [StreamDelta], error: (any Error)?) {
    var deltas: [StreamDelta] = []
    do {
        for try await delta in stream {
            deltas.append(delta)
        }
        return (deltas, nil)
    } catch {
        return (deltas, error)
    }
}

func assertProviderTerminationMissing(_ error: (any Error)?) {
    guard let agentError = error as? AgentError,
          case let .llmError(transport) = agentError else {
        Issue.record("Expected providerTerminationMissing, got \(String(describing: error))")
        return
    }
    guard case .streamFailed(.providerTerminationMissing) = transport else {
        Issue.record("Expected providerTerminationMissing, got \(transport)")
        return
    }
}
