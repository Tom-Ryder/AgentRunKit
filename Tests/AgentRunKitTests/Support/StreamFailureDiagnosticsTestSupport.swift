@testable import AgentRunKit
import Foundation

extension StreamFailureDiagnostics {
    static let empty = StreamFailureDiagnostics(
        provider: .custom("test"),
        elapsed: .zero,
        eventsObserved: 0,
        finishSignalSeen: false,
        lastEvent: nil
    )
}
