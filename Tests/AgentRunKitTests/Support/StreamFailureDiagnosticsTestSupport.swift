@testable import AgentRunKit
import Foundation

extension StreamFailureDiagnostics {
    static let empty = StreamFailureDiagnostics(elapsed: .zero, eventsObserved: 0, lastEvent: nil)
}
