@testable import AgentRunKit
import Foundation

actor CountingApprovalHandler {
    private var decisions: [String: ToolApprovalDecision]
    private let defaultDecision: ToolApprovalDecision

    private(set) var requestCount = 0
    private(set) var requests: [ToolApprovalRequest] = []

    init(decisions: [String: ToolApprovalDecision] = [:], defaultDecision: ToolApprovalDecision = .approve) {
        self.decisions = decisions
        self.defaultDecision = defaultDecision
    }

    func handle(_ request: ToolApprovalRequest) -> ToolApprovalDecision {
        requests.append(request)
        requestCount += 1
        return decisions[request.toolName] ?? defaultDecision
    }

    nonisolated var handler: ToolApprovalHandler {
        { request in
            await self.handle(request)
        }
    }
}

actor BlockingApprovalHandler {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    private(set) var requestCount = 0
    private(set) var requests: [ToolApprovalRequest] = []

    func handle(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        requests.append(request)
        requestCount += 1

        if !isReleased {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        return .approve
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }

    nonisolated var handler: ToolApprovalHandler {
        { request in
            await self.handle(request)
        }
    }
}
